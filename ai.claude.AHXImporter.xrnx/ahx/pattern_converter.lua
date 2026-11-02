-- Converts AHX track steps of a segment into neutral pattern data (no Renoise API), keeping per-channel state
-- (current note, instrument, volume, portamento) and the tempo across segments.
--
-- Output cell values are Renoise values: note 0..119, instrument 0-based, volume 0..0x80, delay 0..255,
-- effects as { number = 'ZT', amount = 0..255 }.
--
-- The volume is not a pattern command either: the converter computes the AHX output volume of every frame (envelope
-- and performance list of the instrument simulation, note volume, voice master volume, note cut, hard cut release) and
-- writes it as automation points of macro 1 ("Volume") of the playing instrument (see `advance_volume`). Instruments
-- on the Renoise-filter path get their cutoff per frame (Hz) the same way (macro 2 "Cutoff").
--
-- Pitch slides are not pattern commands: the converter runs the track portamento per frame and records, for every
-- trigger, the slide periods until the channel's next trigger (`triggers`). Those become variant phrases with the
-- slide baked in (see `Portamento`, `NoteUsage`), selected with 0Zxx on the trigger row.

local bit = require('bit')

local FilterPath = require('ahx.filter_path')
local Portamento = require('ahx.portamento')
local Resolution = require('ahx.resolution')
local Simulator = require('ahx.simulator')
local Tables = require('ahx.tables')
local Timing = require('ahx.timing')

local PatternConverter = {}
PatternConverter.__index = PatternConverter

-- AHX note n is Renoise note n + 11 (AHX C-1 = Renoise C-1 = 12).
local NOTE_OFFSET = 11
local FULL_VOLUME = 0x40

---@class AhxCell
---@field note integer|nil
---@field legato boolean|nil retrigger of a note without instrument (AHX keeps the instrument running)
---@field delay_frames integer|nil frames after the row start (note delay); placed by `convert`
---@field vibrato { amount: integer, first_sub: integer }|nil 0Vxy from sub line `first_sub` on; placed by `convert`
---@field instrument integer|nil
---@field volume integer|nil
---@field delay integer|nil
---@field effects { number: string, amount: integer }[]

---@class AhxTrigger
---@field id string `segment index .. ':' .. row .. ':' .. channel`
---@field instrument integer AHX instrument number
---@field note integer Renoise note the phrase is triggered with
---@field square_offset integer|nil 9xx parameter on the trigger row
---@field slides integer[] slide period per frame from the trigger frame on, until the channel's next trigger

---@class AhxVolumePoint
---@field time number pattern line (1-based) plus 1/256 line fraction
---@field instrument integer AHX instrument number whose volume macro is set
---@field value number 0..1 (AHX output volume / 64)

---@class AhxCutoffPoint
---@field time number pattern line (1-based) plus 1/256 line fraction
---@field instrument integer Renoise instrument index whose filter macro is set
---@field value number|false cutoff in Hz, false = filter open

---@class AhxPatternData
---@field segment AhxSegment
---@field number_of_lines integer
---@field channels table<integer, table<integer, AhxCell>> channels[1..4][line 1..n], only non-empty cells
---@field volumes table<integer, AhxVolumePoint[]> volume automation points per channel, in time order
---@field cutoffs table<integer, AhxCutoffPoint[]> cutoff automation points per channel, in time order
---@field effect_columns integer highest number of effects in one cell
---@field uses_delay boolean
---@field key string content fingerprint for de-duplication

---@param song AhxSong
---@param plan AhxTimingPlan
---@param report fun(name: string) collects commands that are not converted (yet)
---@param variant_phrases table<integer, table<string, integer>> variant phrase index by instrument and variant key
---@param lines_per_row integer|nil pattern lines per AHX row (pattern resolution option, default 1)
---@param trigger_keys table<string, string>|nil variant key by trigger id (from a previous pass, see `NoteUsage`)
---@param slots table<integer, table<integer, integer>>|nil Renoise instrument index per channel and AHX instrument
---(one instance per track, see `InstrumentSlots`); missing = the AHX instrument number
---@param filter_sides table<integer, 'low'|'high'>|nil Renoise-filter side per AHX instrument (`FilterPath`)
---@return table converter
function PatternConverter.new(song, plan, report, variant_phrases, lines_per_row, trigger_keys, slots, filter_sides)
  local self = setmetatable({}, PatternConverter)
  self.song = song
  self.plan = plan
  self.variant_phrases = variant_phrases or {}
  self.trigger_keys = trigger_keys or {}
  self.slots = slots or {}
  self.filter_sides = filter_sides or {}
  -- AHX instruments per channel in the order of their first use (pre-pass: every track gets its own instances, see
  -- `InstrumentSlots`).
  self.channel_instruments = { {}, {}, {}, {} }
  self.channel_seen = { {}, {}, {}, {} }
  ---@type AhxTrigger[]
  self.triggers = {}
  self.lines_per_row = lines_per_row or 1
  self.report_unsupported = function(_, name)
    report(name)
  end
  self.tempo = Timing.INITIAL_SPEED
  -- Plain instrument simulations (the volume does not depend on the pitch or a square offset), by instrument number.
  self.simulations = {}
  -- Frames since the start of the sequence, and the pattern time of the previous frame (nil at a segment start).
  self.frame_counter = 0
  self.previous_time = nil
  self.channels = {}
  for channel = 1, 4 do
    self.channels[channel] = {
      note = nil,
      instrument = 0,
      -- Note volume (`NoteMaxVolume`) and the changes of the current step, applied in the step's frame.
      volume = FULL_VOLUME,
      step_volume_set = nil,
      step_volume_add = 0,
      slide_delta = 0,
      -- Instrument simulation of the playing note and the number of frames played since its trigger.
      simulation = nil,
      simulation_frame = 0,
      -- Hard cut release in progress: envelope volume, change per frame, frames left.
      release = nil,
      hard_cut_release = false,
      -- Note cut of the current row: frame of the row, with release.
      cut_frame = nil,
      cut_release = false,
      -- Last written automation value per instrument and the frame counter of that point (see `emit_point`).
      volume_track = { values = {}, frames = {} },
      cutoff_track = { values = {}, frames = {} },
      -- Track portamento period and track note of the frames of the current row (`advance_portamento`).
      frame_slides = {},
      frame_track_notes = {},
      portamento = Portamento.new(),
      -- Trigger whose slide periods are being recorded.
      trigger = nil,
      step_delay = 0,
      vibrato = nil,
      frames = 0,
      track_master_volume = FULL_VOLUME,
      hard_cut = 0,
    }
  end
  return self
end

-- Phrases have at most 512 lines, so longer slides are not recorded.
local MAX_SLIDE_FRAMES = 512

-- Instrument vibrato as pattern vibrato 0Vxy on every row once the vibrato delay has run out (an LFO in the
-- instrument restarts with every sample switch of the phrase).
-- Speed: AHX advances a 64-step sine by `speed` per frame, i.e. the vibrato rate is fixed in Hz. Renoise's 0Vxy rate
-- follows the lines (rate ∝ x · lines per second), so x = speed · song speed / (6 · lines per row) (verified by ear:
-- xeron - 64k is all you need at speed 3 / 1×, pink - thanatos remix at speed 16 / 2×). x is at most F, so slow
-- songs need a higher pattern resolution (see `Resolution`).
-- Depth: AHX adds `sine · depth >> 7` to the period, so the depth in semitones depends on the note (high notes have
-- small periods). It is converted per row at the current note; Renoise depth is semitone-based.
-- y = depth in 1/8 semitones (verified by ear: xeron - 64k is all you need, syphus - better days).
local VIBRATO_DEPTH_UNITS_PER_SEMITONE = 8

---Peak vibrato deviation in semitones for an AHX vibrato depth at a note (average of up and down).
---@param depth integer 0..15
---@param note integer|nil Renoise note
---@return number
local function vibrato_semitones(depth, note)
  local ahx_note = math.max(1, math.min(60, (note or 36) - NOTE_OFFSET))
  local period = Tables.PERIODS[ahx_note]
  local offset = bit.arshift(255 * depth, 7)
  local up = math.log(period / math.max(1, period - offset))
  local down = math.log((period + offset) / period)
  return 12 * (up + down) / 2 / math.log(2)
end

---@param cell AhxCell
---@param number string
---@param amount integer
local function add_effect(cell, number, amount)
  cell.effects[#cell.effects + 1] = { number = number, amount = amount }
end

---Writes the Z commands for a speed change (the BPM stays constant, see `Timing`).
---@param cell AhxCell
---@param tempo integer
function PatternConverter:add_tempo(cell, tempo)
  local lpb, tpl, exact = Timing.for_speed(self.plan, tempo, self.lines_per_row)
  if not exact then
    self:report_unsupported(('speed %d (approximated)'):format(tempo))
  end
  add_effect(cell, 'ZL', lpb)
  add_effect(cell, 'ZK', tpl)
end

---Renoise instrument index of an AHX instrument on a channel (every track has its own instances).
---@param channel integer
---@param instrument integer AHX instrument number
---@return integer
function PatternConverter:slot(channel, instrument)
  local slots = self.slots[channel]
  return slots and slots[instrument] or instrument
end

---Converts one step of one channel.
---@param channel integer 1..4
---@param step AhxStep
---@param transpose integer position transpose of the channel
---@param next_instrument integer instrument of the channel's next step (as the replayer's hard cut looks ahead)
---@return AhxCell
function PatternConverter:convert_step(channel, step, transpose, next_instrument)
  local state = self.channels[channel]
  local cell = { effects = {} }
  local fx = step.fx
  local param = step.fx_param
  local low = bit.band(param, 0x0f)
  local high = bit.rshift(param, 4)

  local note = nil
  if step.note > 0 then
    note = math.max(0, math.min(119, step.note + transpose + NOTE_OFFSET))
  end

  -- The row's speed is already set by `convert` (the replayer runs all steps of a row before its frames).
  if fx == 0xf and param > 0 then
    self:add_tempo(cell, param)
  end

  -- Note delay (the replayer processes the whole step, also its portamento, after the delay)
  state.step_delay = 0
  if fx == 0xe and high == 0xd and low > 0 and low < self.tempo then
    cell.delay_frames = low
    state.step_delay = low
  end

  -- Volume changes of the step, in the replayer's order: the instrument resets the note volume, Cxx sets it, EAx/EBx
  -- change it. They apply in the step's frame (`advance_volume`).
  state.step_volume_set = nil
  state.step_volume_add = 0
  state.slide_delta = 0
  state.cut_frame = nil

  local instrument = step.instrument
  if instrument > 0 then
    state.instrument = instrument
    local triggered_instrument = self.song.instruments[instrument]
    state.hard_cut = triggered_instrument and triggered_instrument.hard_cut_release_frames or 0
    state.hard_cut_release = triggered_instrument ~= nil and triggered_instrument.hard_cut_release ~= 0
    state.step_volume_set = triggered_instrument and triggered_instrument.volume or 0
    -- An instrument number beyond the song's instruments plays the replayer's empty instrument: silence.
    if triggered_instrument then
      cell.instrument = self:slot(channel, instrument) - 1
    end
    if triggered_instrument and not self.channel_seen[channel][instrument] then
      self.channel_seen[channel][instrument] = true
      local order = self.channel_instruments[channel]
      order[#order + 1] = instrument
    end
  end

  -- Tone portamento (3xx, 5xx): the note does not trigger, it only sets the slide target (like the replayer). An
  -- instrument on the same row retriggers at the current note, like an instrument without note.
  local tone_portamento = fx == 0x3 or fx == 0x5
  if tone_portamento then
    if instrument > 0 then
      cell.note = state.note
    end
  elseif note then
    cell.note = note
    if instrument == 0 and state.note and state.instrument > 0 and self.song.instruments[state.instrument] then
      -- AHX changes the pitch without retriggering the instrument. A pattern glide (0GFF) fought with the absolute
      -- pitches of the phrase whenever the phrase switches samples (distorted sound with PWM, syphus - galactic
      -- olympics AHX 3 / instrument 07), so the note is retriggered with the instrument; the phrase of the new note
      -- starts from its beginning. The note volume and the running vibrato stay as in AHX.
      cell.instrument = self:slot(channel, state.instrument) - 1
      cell.legato = true
    end
    state.note = note
  elseif instrument > 0 then
    -- Instrument without note: AHX retriggers the instrument at the current pitch.
    cell.note = state.note
  end

  if cell.instrument and not cell.note then
    -- Nothing to retrigger yet.
    cell.instrument = nil
  end

  -- Variant phrase of the trigger: square offset (9xx) and/or the slide that follows (1xx, 2xx, 3xx, 5xx, E1x, E2x).
  -- 0Zxx plays phrase xx of the instrument for this note, also in keymap mode (verified by ear).
  if cell.instrument then
    local key = self.trigger_keys[self.row_id .. ':' .. channel]
    if key then
      local variants = self.variant_phrases[state.instrument]
      local index = variants and variants[key]
      if index then
        add_effect(cell, '0Z', index)
      else
        self:report_unsupported('variant phrase beyond the phrase limit (played without slide / 9xx)')
      end
    end
  end

  if fx == 0xc then
    if param <= 0x40 then
      state.step_volume_set = param
      state.step_volume_add = 0
    elseif param - 0x50 <= 0x40 then
      -- C50..C90: master volume of all voices. The replayer runs all steps of a row before its frames, so it applies
      -- to all channels from this row on.
      for other = 1, 4 do
        self.channels[other].track_master_volume = math.max(0, param - 0x50)
      end
    elseif param - 0xa0 >= 0 and param - 0xa0 <= 0x40 then
      -- CA0..CE0: master volume of this voice.
      state.track_master_volume = param - 0xa0
    end
  elseif fx == 0xe then
    if high == 0xa then
      state.step_volume_add = state.step_volume_add + low
    elseif high == 0xb then
      state.step_volume_add = state.step_volume_add - low
    elseif high == 0xc then
      if low > 0 and low < self.tempo then
        -- Note cut after `low` frames: the note volume drops to 0 (`advance_volume`).
        state.cut_frame = low
        state.cut_release = false
        state.hard_cut_release = false
        state.hard_cut = 0
      end
    elseif high == 0x4 then
      state.new_vibrato_depth = low
    end
  elseif fx == 0x9 then
    -- The square offset changes how the instrument starts (variant phrase, see above).
    if not cell.instrument then
      self:report_unsupported('9xx without trigger')
    end
  elseif fx == 0x4 then
    self:report_unsupported('4xx filter override')
  end

  -- Hard cut: an instrument with hard cut frames ends its note that many frames before the next row that triggers an
  -- instrument, with a release over those frames when the instrument says so (`advance_volume`).
  if state.hard_cut > 0 and next_instrument > 0 then
    if not state.cut_frame then
      state.cut_frame = math.max(0, self.tempo - state.hard_cut)
      state.cut_release = state.hard_cut_release
    end
    state.hard_cut = 0
  end

  -- Volume slides (A, 5) change the note volume in every frame from the step's frame on.
  if fx == 0x5 or fx == 0xa then
    state.slide_delta = high - low
  end

  self:add_vibrato(cell, state)

  return cell
end

---Runs the track portamento of one channel through the frames of a row (the step's part in its frame: at the row
---start or after the note delay) and records the slide period of every frame for the channel's current trigger.
---@param channel integer 1..4
---@param cell AhxCell the converted cell of the step (a trigger when it has an instrument)
---@param step AhxStep
function PatternConverter:advance_portamento(channel, cell, step)
  local state = self.channels[channel]
  local portamento = state.portamento
  for frame = 0, self.tempo - 1 do
    if frame == state.step_delay then
      Portamento.process_step(portamento, step)
      if cell.instrument then
        state.trigger = {
          id = self.row_id .. ':' .. channel,
          instrument = state.instrument,
          note = cell.note,
          square_offset = step.fx == 0x9 and step.fx_param or nil,
          slides = {},
        }
        self.triggers[#self.triggers + 1] = state.trigger
      end
    end
    Portamento.process_frame(portamento)
    state.frame_slides[frame] = portamento.period
    state.frame_track_notes[frame] = portamento.track_note
    local trigger = state.trigger
    if trigger and #trigger.slides < MAX_SLIDE_FRAMES then
      trigger.slides[#trigger.slides + 1] = portamento.period
    end
  end
end

---@param instrument integer
---@return AhxSimulation|nil
function PatternConverter:simulation(instrument)
  local simulation = self.simulations[instrument]
  if simulation == nil then
    local definition = self.song.instruments[instrument]
    simulation = definition and Simulator.run(self.song, definition) or false
    self.simulations[instrument] = simulation
  end
  return simulation or nil
end

---Frame `index` (1-based, frames since the trigger) of a simulation; the loop repeats, without loop the last frame
---holds.
---@param simulation AhxSimulation
---@param index integer
---@return AhxFrame
local function simulation_frame(simulation, index)
  local frames = simulation.frames
  if index <= #frames then
    return frames[index]
  end
  if simulation.loop_start then
    local length = simulation.loop_end - simulation.loop_start + 1
    return frames[simulation.loop_start + (index - simulation.loop_start) % length]
  end
  return frames[#frames]
end

-- Automation time between the two points of a hard step (the smallest automation time unit, 1/256 line).
local STEP_TIME = 1 / 256

---Adds an automation point where the value of an instrument's macro changes. Automation uses lines mode: a change
---after a constant stretch gets a point on the previous frame too, so the line only ramps between neighboring frames
---(the AHX value changes once per frame). A hard step (trigger, note cut) gets its previous value 1/256 line before
---the change instead: the new note must start at its own value, and the previous note (which keeps looping silently,
---there are no note-offs) must not be faded in during the frame before.
---@param track { values: table, frames: table } last written value and its frame counter per instrument
---@param points table the channel's points of the segment
---@param instrument integer Renoise instrument index
---@param value any
---@param default any value before the first point (nil = unknown, no extra point)
---@param counter integer frame counter of this frame
---@param previous_time number|nil pattern time of the previous frame (nil at a segment start)
---@param time number pattern time of this frame
---@param hard boolean jump at this frame instead of a ramp from the previous frame
local function emit_point(track, points, instrument, value, default, counter, previous_time, time, hard)
  local last = track.values[instrument]
  if last == nil then
    last = default
  end
  if last == value then
    return
  end
  if last ~= nil and hard and time - STEP_TIME >= 1 then
    points[#points + 1] = { time = time - STEP_TIME, instrument = instrument, value = last }
  elseif last ~= nil and previous_time and track.frames[instrument] ~= counter - 1 then
    points[#points + 1] = { time = previous_time, instrument = instrument, value = last }
  end
  points[#points + 1] = { time = time, instrument = instrument, value = value }
  track.values[instrument] = value
  track.frames[instrument] = counter
end

---Runs the volume of one channel through the frames of a row and adds automation points of the playing instrument's
---volume macro where it changes. Port of the volume part of `ProcessStep` / `ProcessFrame` / `SetAudio`:
---output = envelope · performance volume (instrument simulation) · note volume · voice master volume.
---Instruments on the Renoise-filter path also get the cutoff of every frame (filter macro).
---@param channel integer 1..4
---@param step AhxStep
---@param transpose integer position transpose of the channel
---@param times number[] pattern time of the frames 0 .. tempo - 1 of the row
---@param data AhxPatternData
function PatternConverter:advance_volume(channel, step, transpose, times, data)
  local state = self.channels[channel]
  for frame = 0, self.tempo - 1 do
    local counter = self.frame_counter + frame
    local hard = false
    if frame == state.step_delay then
      -- An instrument restarts the instrument (envelope, performance list); a note without instrument does not.
      if step.instrument > 0 then
        hard = true
        state.simulation = self:simulation(step.instrument)
        state.simulation_frame = 0
        state.release = nil
      end
      local volume = state.step_volume_set or state.volume
      state.volume = math.max(0, math.min(FULL_VOLUME, volume + state.step_volume_add))
    end

    -- Note cut / hard cut: without release the note volume drops to 0; with release the envelope fades from its
    -- current volume to the instrument's release volume over the remaining frames of the row.
    if state.cut_frame == frame then
      local simulation = state.simulation
      if state.cut_release and simulation then
        local adsr = state.release and state.release.adsr
          or (state.simulation_frame > 0 and simulation_frame(simulation, state.simulation_frame).adsr or 0)
        local release_volume = self.song.instruments[state.instrument].envelope.r_volume * 256
        local frames = math.max(1, self.tempo - frame)
        state.release = {
          adsr = adsr,
          step = -(adsr - release_volume) / frames,
          frames = frames,
          target = release_volume,
        }
      else
        state.volume = 0
        hard = true
      end
    end

    if frame >= state.step_delay then
      state.volume = math.max(0, math.min(FULL_VOLUME, state.volume + state.slide_delta))
    end

    local output = 0
    local cutoff = nil
    local simulation = state.simulation
    if simulation then
      state.simulation_frame = state.simulation_frame + 1
      local record = simulation_frame(simulation, state.simulation_frame)
      -- The performance list runs after the volume slide and overwrites the voice's note / master volume.
      if record.note_max_set then
        state.volume = record.note_max_set
      end
      if record.track_master_set then
        state.track_master_volume = record.track_master_set
      end
      local side = self.filter_sides[state.instrument]
      if side then
        local track_note = math.max(0, math.min(60, state.frame_track_notes[frame] + transpose))
        cutoff = FilterPath.cutoff(record, side, track_note, state.frame_slides[frame])
      end
      local adsr = record.adsr
      local release = state.release
      if release then
        if release.frames > 0 then
          release.adsr = release.adsr + release.step
          release.frames = release.frames - 1
          if release.frames <= 0 then
            release.adsr = release.target
          end
        end
        adsr = release.adsr
      end
      output = Simulator.output_volume(adsr, state.volume, record.perf_sub_volume, state.track_master_volume)
    end

    -- (`song.instruments[0]` is the replayer's empty instrument.)
    local valid = state.instrument > 0 and self.song.instruments[state.instrument] ~= nil
    local instrument = valid and self:slot(channel, state.instrument) or 0
    if instrument > 0 then
      local previous_time = frame > 0 and times[frame - 1] or self.previous_time
      local time = times[frame]
      local value = math.max(0, math.min(FULL_VOLUME, output)) / FULL_VOLUME
      local volumes, cutoffs = data.volumes[channel], data.cutoffs[channel]
      emit_point(state.volume_track, volumes, instrument, value, 0, counter, previous_time, time, hard)
      if cutoff ~= nil then
        emit_point(state.cutoff_track, cutoffs, instrument, cutoff, nil, counter, previous_time, time, hard)
      end
    end
  end
end

---Prepends a point on the first line for the playing instrument of a channel and for every instrument the channel
---sets in the segment (a pattern can be reached from different places: loop, reuse). Without a value at the segment
---start, the instrument's first point of the segment is used.
---@param lists table<integer, table[]> points per channel
---@param channel integer
---@param start table<integer, any> value per instrument at the segment start
---@param playing integer Renoise instrument playing at the segment start (0 = none)
local function add_start_points(lists, channel, start, playing)
  local points = lists[channel]
  local needed = {}
  if playing > 0 and start[playing] ~= nil then
    needed[playing] = true
  end
  for _, point in ipairs(points) do
    needed[point.instrument] = true
  end
  for _, point in ipairs(points) do
    if point.time == 1 then
      needed[point.instrument] = nil
    end
  end
  local instruments = {}
  for instrument in pairs(needed) do
    instruments[#instruments + 1] = instrument
  end
  table.sort(instruments)
  local result = {}
  for _, instrument in ipairs(instruments) do
    local value = start[instrument]
    if value == nil then
      for _, point in ipairs(points) do
        if point.instrument == instrument then
          value = point.value
          break
        end
      end
    end
    result[#result + 1] = { time = 1, instrument = instrument, value = value }
  end
  for _, point in ipairs(points) do
    result[#result + 1] = point
  end
  lists[channel] = result
end

---Writes 0Vxy on rows where the instrument vibrato is running (after its delay, until the next trigger).
---@param cell AhxCell
---@param state table channel state
function PatternConverter:add_vibrato(cell, state)
  if cell.instrument and not cell.legato then
    local instrument = self.song.instruments[state.instrument]
    state.vibrato = {
      depth = instrument.vibrato_depth,
      speed = instrument.vibrato_speed,
      delay = instrument.vibrato_delay,
    }
    state.frames = 0
  end
  -- E4x changes the depth after the instrument trigger of the same row.
  if state.new_vibrato_depth then
    if state.vibrato then
      state.vibrato.depth = state.new_vibrato_depth
    end
    state.new_vibrato_depth = nil
  end

  local vibrato = state.vibrato
  -- The replayer starts the vibrato in the first frame after `delay` frames. A row spans `lines_per_row` lines; the
  -- vibrato starts on the first line whose middle lies behind the delay (a whole row at once started it too early with
  -- a long delay and slow speed: pink - thanatos remix, speed 16, delay 8).
  local frames_per_line = self.tempo / self.lines_per_row
  local first_sub = nil
  if vibrato then
    for sub = 0, self.lines_per_row - 1 do
      if state.frames + (sub + 0.5) * frames_per_line > vibrato.delay then
        first_sub = sub
        break
      end
    end
  end
  if vibrato and vibrato.depth > 0 and vibrato.speed > 0 and first_sub then
    local speed = Resolution.vibrato_speed(vibrato.speed, self.tempo, self.lines_per_row)
    local depth = math.floor(vibrato_semitones(vibrato.depth, state.note) * VIBRATO_DEPTH_UNITS_PER_SEMITONE + 0.5)
    if speed > 15 or depth > 15 then
      self:report_unsupported('vibrato speed/depth above F (clamped)')
    end
    -- Depth 0: the vibrato is too small to hear at this pitch (and 0V with y = 0 may continue the previous depth).
    if depth > 0 then
      cell.vibrato = { amount = math.min(15, math.max(1, speed)) * 16 + math.min(15, depth), first_sub = first_sub }
    end
  end
  state.frames = state.frames + self.tempo
end

---@param cell AhxCell
---@return boolean
local function is_empty(cell)
  return cell.note == nil
    and cell.instrument == nil
    and cell.volume == nil
    and cell.delay == nil
    and cell.delay_frames == nil
    and #cell.effects == 0
end

---@param cell AhxCell
---@return string
local function cell_key(cell)
  local note = cell.note or ''
  local parts = { note, cell.instrument or '', cell.volume or '', cell.delay or '' }
  for _, effect in ipairs(cell.effects) do
    parts[#parts + 1] = effect.number .. effect.amount
  end
  return table.concat(parts, ',')
end

---Merges a cell into the line of a channel (keeps existing values, appends effects).
---@param lines table<integer, AhxCell>
---@param line integer
---@param cell AhxCell
local function merge(lines, line, cell)
  local existing = lines[line]
  if not existing then
    lines[line] = cell
    return
  end
  for _, field in ipairs({ 'note', 'instrument', 'volume', 'delay' }) do
    if existing[field] == nil then
      existing[field] = cell[field]
    end
  end
  for _, effect in ipairs(cell.effects) do
    existing.effects[#existing.effects + 1] = effect
  end
end

---Places the cell of one row on its pattern lines. A row spans `lines_per_row` lines: a delayed note goes to the sub
---line of its frame with the remaining fraction in the delay column, and the vibrato command is repeated on every line
---of the row.
---@param lines table<integer, AhxCell>
---@param line integer first line of the row
---@param cell AhxCell
function PatternConverter:place(lines, line, cell)
  local per_row = self.lines_per_row
  local frames = cell.delay_frames
  cell.delay_frames = nil

  if frames then
    local position = frames * per_row / self.tempo
    local sub = math.floor(position)
    local delay = math.min(255, math.floor((position - sub) * 256))
    if sub == 0 then
      cell.delay = delay
    else
      -- Note delay: the whole step moves (the replayer processes the step only after the delay).
      cell.delay = delay
      merge(lines, line + sub, cell)
      cell = { effects = {} }
    end
  end

  local vibrato = cell.vibrato
  cell.vibrato = nil
  if vibrato then
    for sub = vibrato.first_sub, per_row - 1 do
      if sub == 0 then
        add_effect(cell, '0V', vibrato.amount)
      else
        merge(lines, line + sub, { effects = { { number = '0V', amount = vibrato.amount } } })
      end
    end
  end

  if not is_empty(cell) then
    merge(lines, line, cell)
  end
end

---Converts one segment into pattern data.
---@param segment AhxSegment
---@param segment_index integer index of the segment in the sequence (identifies triggers across passes)
---@return AhxPatternData
function PatternConverter:convert(segment, segment_index)
  local song = self.song
  local position = song.positions[segment.position]
  local data = {
    segment = segment,
    number_of_lines = (segment.last_row - segment.first_row + 1) * self.lines_per_row,
    channels = { {}, {}, {}, {} },
    volumes = { {}, {}, {}, {} },
    cutoffs = { {}, {}, {}, {} },
    effect_columns = 0,
    uses_delay = false,
  }
  local key_parts = { data.number_of_lines }
  -- The replayer's look-ahead (hard cut) uses the next position of the list, regardless of jumps.
  local next_position = song.positions[(segment.position + 1) % song.position_count]
  -- Automation values at the segment start (see `add_start_points`).
  local start_volumes, start_cutoffs, start_instruments = {}, {}, {}
  for channel = 1, 4 do
    local state = self.channels[channel]
    start_volumes[channel], start_cutoffs[channel] = {}, {}
    for instrument, value in pairs(state.volume_track.values) do
      start_volumes[channel][instrument] = value
    end
    for instrument, value in pairs(state.cutoff_track.values) do
      start_cutoffs[channel][instrument] = value
    end
    local valid = state.instrument > 0 and self.song.instruments[state.instrument] ~= nil
    start_instruments[channel] = valid and self:slot(channel, state.instrument) or 0
  end
  self.previous_time = nil

  for row = segment.first_row, segment.last_row do
    local line = (row - segment.first_row) * self.lines_per_row + 1
    -- The replayer processes the steps of all four voices before the frames of the row, so a speed command in any
    -- channel already applies to the frame timing (note delay, note cut, hard cut, slides) of all channels of this
    -- row (mobby - good day: swing via F05/F0A on AHX 2, hard cut bass on AHX 1).
    for channel = 1, 4 do
      local step = song.tracks[position.track[channel - 1]][row]
      if step.fx == 0xf and step.fx_param > 0 then
        self.tempo = step.fx_param
      end
    end

    self.row_id = segment_index .. ':' .. row
    local cells = {}
    for channel = 1, 4 do
      local steps = song.tracks[position.track[channel - 1]]
      local next_step
      if row + 1 < song.track_length then
        next_step = steps[row + 1]
      else
        next_step = song.tracks[next_position.track[channel - 1]][0]
      end
      cells[channel] = self:convert_step(channel, steps[row], position.transpose[channel - 1], next_step.instrument)
    end

    -- Pattern time of every frame of the row: tick `frame` of the row (a tick is a frame). Automation times are
    -- quantized to 1/256 line; rounded down, so a point is never behind the tick of its frame (Renoise updates the
    -- automation per tick).
    local times = {}
    for frame = 0, self.tempo - 1 do
      times[frame] = line + math.floor(frame * self.lines_per_row * 256 / self.tempo) / 256
    end
    for channel = 1, 4 do
      local step = song.tracks[position.track[channel - 1]][row]
      self:advance_portamento(channel, cells[channel], step)
      self:advance_volume(channel, step, position.transpose[channel - 1], times, data)
    end
    self.frame_counter = self.frame_counter + self.tempo
    self.previous_time = times[self.tempo - 1]

    for channel = 1, 4 do
      self:place(data.channels[channel], line, cells[channel])
    end
  end

  for channel = 1, 4 do
    add_start_points(data.volumes, channel, start_volumes[channel], start_instruments[channel])
    add_start_points(data.cutoffs, channel, start_cutoffs[channel], start_instruments[channel])
    for _, point in ipairs(data.volumes[channel]) do
      key_parts[#key_parts + 1] = ('v%d:%s:%d=%.4f'):format(channel, point.time, point.instrument, point.value)
    end
    for _, point in ipairs(data.cutoffs[channel]) do
      key_parts[#key_parts + 1] = ('c%d:%s:%d=%s'):format(channel, point.time, point.instrument, tostring(point.value))
    end
    for line = 1, data.number_of_lines do
      local cell = data.channels[channel][line]
      if cell then
        data.effect_columns = math.max(data.effect_columns, #cell.effects)
        data.uses_delay = data.uses_delay or cell.delay ~= nil
        key_parts[#key_parts + 1] = ('%d:%d=%s'):format(line, channel, cell_key(cell))
      end
    end
  end

  data.key = table.concat(key_parts, ';')
  return data
end

---Pre-pass before the instruments are written: all triggers of a sequence with the slide that follows each of them
---(they decide the variant phrases), and the AHX instruments of every channel in the order of their first use (each
---track gets its own instances, see `InstrumentSlots`).
---@param song AhxSong
---@param plan AhxTimingPlan
---@param sequence AhxSequence
---@return AhxTrigger[] triggers
---@return integer[][] channel_instruments AHX instrument numbers per channel 1..4
function PatternConverter.scan_triggers(song, plan, sequence)
  local converter = PatternConverter.new(song, plan, function() end, {}, 1)
  for index, segment in ipairs(sequence.segments) do
    converter:convert(segment, index)
  end
  return converter.triggers, converter.channel_instruments
end

return PatternConverter
