-- Frame simulator: plays one AHX instrument from note-on, frame by frame, without audio.
-- Port of the instrument part of `ProcessStep` (instrument trigger) and `ProcessFrame` / `PListCommandParse` of the
-- reference replayer. Pattern commands, vibrato, hard cut and note cut/delay are not part of it: the pattern converter
-- handles them (the volume per frame, including the hard cut release, see `PatternConverter:advance_volume`).
--
-- The result describes every frame (one phrase line each) and the loop the frames fall into, detected by comparing
-- the complete voice state.

local bit = require('bit')

local Simulator = {}

-- A phrase has at most 512 lines.
local MAX_FRAMES = 512

---JS `x >> n` on a number (ToInt32 truncates toward zero first).
---@param value number
---@param shift integer
---@return integer
local function arshift(value, shift)
  local truncated = value >= 0 and math.floor(value) or math.ceil(value)
  return bit.arshift(truncated, shift)
end

---@class AhxFrame
---@field waveform integer 0..3
---@field filter_pos integer 1..63
---@field square_pos integer
---@field instr_period integer performance list note (0 = none yet)
---@field fixed boolean the note is fixed (ignores the track note)
---@field perf_slide_period integer period offset of the performance list portamento
---@field volume integer 0..64, envelope · performance volume relative to the instrument volume
---@field adsr number envelope volume (`ADSRVolume`, 0..64 · 256) after the frame
---@field perf_sub_volume integer performance list volume 0..64
---@field track_master_volume integer voice master volume set by the performance list, 0..64
---@field note_scale number note volume set by the performance list relative to the instrument volume

---@class AhxSimulation
---@field frames AhxFrame[] 1-based, frame 1 = first frame after note-on
---@field loop_start integer|nil 1-based first frame of the loop
---@field loop_end integer|nil 1-based last frame of the loop

---@class AhxSimulationOptions
---@field square_offset integer|nil parameter of a track command 9xx on the trigger row

---Output volume of a frame (0..64, relative to the instrument volume like `AhxFrame.volume`) for an envelope volume:
---the replayer's `((((ADSRVolume >> 8) · PerfSubVolume) >> 6) · TrackMasterVolume) >> 6`, scaled by the note volume
---the performance list set.
---@param frame AhxFrame
---@param adsr number envelope volume (0..64 · 256)
---@return integer
function Simulator.frame_volume(frame, adsr)
  local volume = arshift(arshift(arshift(adsr, 8) * frame.perf_sub_volume, 6) * frame.track_master_volume, 6)
  return math.max(0, math.min(0x40, math.floor(volume * frame.note_scale)))
end

---Simulates an instrument.
---@param song AhxSong
---@param instrument AhxInstrument
---@param options AhxSimulationOptions|nil
---@return AhxSimulation
function Simulator.run(song, instrument, options)
  local revision = song.revision
  local envelope = instrument.envelope
  local plist = instrument.plist
  -- Wave lengths 6 and 7 are invalid (silent in the replayer); clamp so the shifts stay valid.
  local shift = 5 - math.min(instrument.wave_length, 5)

  -- Voice state after an instrument trigger (`ProcessStep`). Fields the replayer keeps from the previous note start
  -- from the values of a fresh voice.
  local v = {
    waveform = 0,
    new_waveform = 0,
    square_pos = 0,
    ignore_square = 0,
    instr_period = 0,
    fixed = 0,
    perf_sub_volume = 0x40,
    note_max_volume = instrument.volume,
    track_master_volume = 0x40,
    adsr_volume = 0,
    a_frames = envelope.a_frames,
    a_volume = envelope.a_volume * 256 / envelope.a_frames,
    d_frames = envelope.d_frames,
    d_volume = (envelope.d_volume - envelope.a_volume) * 256 / envelope.d_frames,
    s_frames = envelope.s_frames,
    r_frames = envelope.r_frames,
    r_volume = (envelope.r_volume - envelope.d_volume) * 256 / envelope.r_frames,
    square_on = 0,
    square_init = 0,
    square_wait = 0,
    square_sign = 0,
    square_sliding_in = 0,
    filter_on = 0,
    filter_init = 0,
    filter_wait = 0,
    filter_sign = 0,
    filter_sliding_in = 0,
    filter_pos = 32,
    perf_current = 0,
    perf_wait = 0,
    perf_speed = plist.speed,
    perf_slide_speed = 0,
    perf_slide_period = 0,
    perf_slide_on = 0,
  }

  local square_lower = arshift(instrument.square_lower_limit, shift)
  local square_upper = arshift(instrument.square_upper_limit, shift)
  if square_upper < square_lower then
    square_lower, square_upper = square_upper, square_lower
  end

  local filter_speed = instrument.filter_speed
  local filter_lower = instrument.filter_lower_limit
  local filter_upper = instrument.filter_upper_limit
  if bit.band(filter_lower, 0x80) ~= 0 then
    filter_speed = bit.bor(filter_speed, 0x20)
  end
  if bit.band(filter_upper, 0x80) ~= 0 then
    filter_speed = bit.bor(filter_speed, 0x40)
  end
  filter_lower = bit.band(filter_lower, 0x7f)
  filter_upper = bit.band(filter_upper, 0x7f)
  if filter_lower > filter_upper then
    filter_lower, filter_upper = filter_upper, filter_lower
  end

  -- Track command 9xx on the trigger row sets the square position and makes the next performance list square
  -- position command (3xx) be ignored once (`ProcessStep`).
  if options and options.square_offset then
    v.square_pos = arshift(options.square_offset, shift)
    v.ignore_square = 1
  end

  local function plist_command(fx, param)
    if fx == 0 then
      if revision > 0 and param ~= 0 then
        v.filter_pos = param
        v.new_waveform = 1
      end
    elseif fx == 1 then
      v.perf_slide_speed = param
      v.perf_slide_on = 1
    elseif fx == 2 then
      v.perf_slide_speed = -param
      v.perf_slide_on = 1
    elseif fx == 3 then
      if v.ignore_square == 0 then
        v.square_pos = arshift(param, shift)
      else
        v.ignore_square = 0
      end
    elseif fx == 4 then
      if revision == 0 or param == 0 then
        v.square_on = bit.bxor(v.square_on, 1)
        v.square_init = v.square_on
        v.square_sign = 1
      else
        if bit.band(param, 0x0f) ~= 0 then
          v.square_on = bit.bxor(v.square_on, 1)
          v.square_init = v.square_on
          v.square_sign = bit.band(param, 0x0f) == 0x0f and -1 or 1
        end
        if bit.band(param, 0xf0) ~= 0 then
          v.filter_on = bit.bxor(v.filter_on, 1)
          v.filter_init = v.filter_on
          v.filter_sign = bit.band(param, 0xf0) == 0xf0 and -1 or 1
        end
      end
    elseif fx == 5 then
      v.perf_current = param
    elseif fx == 6 then
      if param > 0x40 then
        param = param - 0x50
        if param >= 0 then
          if param <= 0x40 then
            v.perf_sub_volume = param
          else
            param = param - (0xa0 - 0x50)
            if param >= 0 and param <= 0x40 then
              v.track_master_volume = param
            end
          end
        end
      else
        v.note_max_volume = param
      end
    elseif fx == 7 then
      v.perf_speed = param
      v.perf_wait = param
    end
  end

  local function process_frame()
    -- Envelope
    if v.a_frames > 0 then
      v.adsr_volume = v.adsr_volume + v.a_volume
      v.a_frames = v.a_frames - 1
      if v.a_frames <= 0 then
        v.adsr_volume = envelope.a_volume * 256
      end
    elseif v.d_frames > 0 then
      v.adsr_volume = v.adsr_volume + v.d_volume
      v.d_frames = v.d_frames - 1
      if v.d_frames <= 0 then
        v.adsr_volume = envelope.d_volume * 256
      end
    elseif v.s_frames > 0 then
      v.s_frames = v.s_frames - 1
    elseif v.r_frames > 0 then
      v.adsr_volume = v.adsr_volume + v.r_volume
      v.r_frames = v.r_frames - 1
      if v.r_frames <= 0 then
        v.adsr_volume = envelope.r_volume * 256
      end
    end

    -- Performance list
    if v.perf_current < plist.length then
      v.perf_wait = v.perf_wait - 1
      if v.perf_wait <= 0 then
        local entry = plist.entries[v.perf_current]
        v.perf_current = v.perf_current + 1
        v.perf_wait = v.perf_speed
        if entry.waveform > 0 then
          v.waveform = entry.waveform - 1
          v.new_waveform = 1
          v.perf_slide_speed = 0
          v.perf_slide_period = 0
        end
        v.perf_slide_on = 0
        for slot = 0, 1 do
          plist_command(entry.fx[slot], entry.fx_param[slot])
        end
        if entry.note > 0 then
          v.instr_period = entry.note
          v.fixed = entry.fixed
        end
      end
    else
      if v.perf_wait ~= 0 then
        v.perf_wait = v.perf_wait - 1
      else
        v.perf_slide_speed = 0
      end
    end

    -- Performance portamento
    if v.perf_slide_on ~= 0 then
      v.perf_slide_period = v.perf_slide_period - v.perf_slide_speed
    end

    -- Pulse width modulation
    if v.waveform == 2 and v.square_on ~= 0 then
      v.square_wait = v.square_wait - 1
      if v.square_wait <= 0 then
        local d3 = v.square_pos
        if v.square_init ~= 0 then
          v.square_init = 0
          if d3 <= square_lower then
            v.square_sliding_in = 1
            v.square_sign = 1
          elseif d3 >= square_upper then
            v.square_sliding_in = 1
            v.square_sign = -1
          end
        end
        if d3 == square_lower or d3 == square_upper then
          if v.square_sliding_in ~= 0 then
            v.square_sliding_in = 0
          else
            v.square_sign = -v.square_sign
          end
        end
        v.square_pos = d3 + v.square_sign
        v.square_wait = instrument.square_speed
      end
    end

    -- Filter modulation
    if v.filter_on ~= 0 then
      v.filter_wait = v.filter_wait - 1
      if v.filter_wait <= 0 then
        local d3 = v.filter_pos
        if v.filter_init ~= 0 then
          v.filter_init = 0
          if d3 <= filter_lower then
            v.filter_sliding_in = 1
            v.filter_sign = 1
          elseif d3 >= filter_upper then
            v.filter_sliding_in = 1
            v.filter_sign = -1
          end
        end
        local steps = filter_speed < 3 and 5 - filter_speed or 1
        for _ = 1, steps do
          if d3 == filter_lower or d3 == filter_upper then
            if v.filter_sliding_in ~= 0 then
              v.filter_sliding_in = 0
            else
              v.filter_sign = -v.filter_sign
            end
          end
          d3 = d3 + v.filter_sign
        end
        v.filter_pos = d3
        v.filter_wait = math.max(1, filter_speed - 3)
      end
    end
  end

  ---Complete state as a string, for loop detection.
  local function signature()
    return table.concat({
      v.waveform,
      v.square_pos,
      v.ignore_square,
      v.instr_period,
      v.fixed,
      v.perf_sub_volume,
      v.note_max_volume,
      v.adsr_volume,
      v.a_frames,
      v.d_frames,
      v.s_frames,
      v.r_frames,
      v.square_on,
      v.square_init,
      v.square_wait,
      v.square_sign,
      v.square_sliding_in,
      v.filter_on,
      v.filter_init,
      v.filter_wait,
      v.filter_sign,
      v.filter_sliding_in,
      v.filter_pos,
      v.perf_current,
      v.perf_wait,
      v.perf_speed,
      v.perf_slide_speed,
      v.perf_slide_period,
      v.perf_slide_on,
    }, ',')
  end

  local result = { frames = {} }
  local seen = {}

  for frame = 1, MAX_FRAMES do
    process_frame()

    -- Output volume relative to the instrument volume (the pattern converter applies the note volume).
    local record = {
      waveform = v.waveform,
      filter_pos = v.filter_pos,
      square_pos = v.square_pos,
      instr_period = v.instr_period,
      fixed = v.fixed ~= 0,
      perf_slide_period = v.perf_slide_period,
      adsr = v.adsr_volume,
      perf_sub_volume = v.perf_sub_volume,
      track_master_volume = v.track_master_volume,
      note_scale = instrument.volume > 0 and v.note_max_volume / instrument.volume or 1,
    }
    record.volume = Simulator.frame_volume(record, v.adsr_volume)
    result.frames[frame] = record

    local key = signature()
    local previous = seen[key]
    if previous then
      -- The state after this frame equals the state after `previous`: frames previous+1 .. frame repeat forever.
      result.loop_start = previous + 1
      result.loop_end = frame
      break
    end
    seen[key] = frame
  end

  return result
end

return Simulator
