-- Builds neutral phrase data (no Renoise API) from a simulated note, for one triggered note: one line per frame with
-- the sample of the frame's waveform state, the absolute pitch and the envelope volume. Only changes are written.
--
-- AHX keeps the playback position when the waveform changes; Renoise restarts a sample on every trigger. To keep the
-- phase, the builder follows the playback position of the cycle (from the pitch of every frame) and starts each
-- switched sample at that position with a sample offset (0Sxx). This depends on the pitch, so there is one phrase per
-- triggered note.
--
-- Pitch: the exact pitch comes from the AHX period (performance note + portamento). The phrase note column only has
-- semitones, so the rest is carried by the sample: every sample is a waveform state with a fine tune (`fine_steps`
-- per semitone). A line addresses its sample by `state_index` and `fine_index`; the instrument writer turns these
-- pairs into sample indices.

local NoteUsage = require('ahx.note_usage')
local Tables = require('ahx.tables')
local Waves = require('ahx.waves')

local PhraseBuilder = {}

-- Phrases have at most 512 lines.
local MAX_LINES = 512

-- Sample rate at base note C-4, see `SampleWriter`.
local SAMPLE_RATE = 8363
local BASE_NOTE = 48

-- Pitch change from one frame to the next that counts as a jump (arpeggio) instead of a slide step.
local JUMP_SEMITONES = 0.5

local MIN_PERIOD = 0x0071
local MAX_PERIOD = 0x0d60

---@class AhxPhraseLine
---@field note integer|nil
---@field instrument integer|nil 0-based sample index (set by the instrument writer from the sample key)
---@field sample_key string|nil `state_index .. ':' .. fine_index`
---@field state_index integer|nil waveform state
---@field fine_index integer|nil fine tune in 1/fine_steps semitones
---@field volume integer|nil 0..0x80
---@field glide boolean|nil pitch change of the playing sample without retrigger
---@field note_off boolean|nil
---@field offset integer|nil sample offset 0..255 (frame of the 256-frame buffer)

---@class AhxPhraseData
---@field note integer the triggering Renoise note
---@field number_of_lines integer
---@field lines table<integer, AhxPhraseLine>
---@field loop_start integer|nil
---@field loop_end integer|nil

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

-- AHX C-3 (period 856) is Renoise C-3 (note 36), see `SampleWriter`.
local REFERENCE_PERIOD = 856
local REFERENCE_NOTE = 36

---Exact Renoise pitch (fractional note) of an AHX note plus a period offset, clamped like the replayer.
---@param ahx_note integer
---@param period_offset integer
---@return number
local function exact_pitch(ahx_note, period_offset)
  local period = clamp(Tables.PERIODS[clamp(ahx_note, 0, 60)] + period_offset, MIN_PERIOD, MAX_PERIOD)
  return REFERENCE_NOTE + 12 * math.log(REFERENCE_PERIOD / period) / math.log(2)
end

---Frames of the simulation; a loop longer than one frame is unrolled up to the phrase length, so the phase stays
---right for as long as possible (only the repeats of the last loop pass can drift).
---A one-frame loop is a steady state. A phrase must keep running to keep its volume (after a one-shot phrase ends, the
---sample plays on at the pattern volume), so a silent steady state ends with a note-off and an audible one becomes a
---two-line loop (Renoise needs loop end > loop start).
---@param simulation AhxSimulation
---@return AhxFrame[] frames
---@return integer|nil loop_start
---@return integer|nil loop_end
---@return boolean note_off end the phrase with a note-off line after the frames
local function unrolled_frames(simulation)
  local frames = {}
  for index, frame in ipairs(simulation.frames) do
    frames[index] = frame
  end

  local loop_start, loop_end = simulation.loop_start, simulation.loop_end
  if not loop_start then
    return frames, nil, nil, false
  end
  if loop_end <= loop_start then
    local last = frames[#frames]
    if last.volume == 0 then
      return frames, nil, nil, true
    end
    frames[#frames + 1] = last
    return frames, #frames - 1, #frames, false
  end

  local length = loop_end - loop_start + 1
  local first = loop_start
  while #frames + length <= MAX_LINES do
    first = #frames + 1
    for index = loop_start, loop_end do
      frames[#frames + 1] = frames[index]
    end
  end
  return frames, first, #frames, false
end

---Builds the phrase of an instrument for one triggering note.
---@param simulation AhxSimulation
---@param state_set AhxWaveStateSet
---@param simulation_index integer index of `simulation` in the state set
---@param trigger_note integer Renoise note the phrase plays
---@param frames_per_second number 50 · speed multiplier
---@param fine_steps integer fine tune steps per semitone (1 = semitones only)
---@return AhxPhraseData
function PhraseBuilder.build(simulation, state_set, simulation_index, trigger_note, frames_per_second, fine_steps)
  local frames, loop_start, loop_end, note_off = unrolled_frames(simulation)
  local data = {
    note = trigger_note,
    number_of_lines = note_off and #frames + 1 or #frames,
    lines = {},
    loop_start = loop_start,
    loop_end = loop_end,
  }
  local track_ahx_note = trigger_note - NoteUsage.NOTE_OFFSET
  local simulated_count = #simulation.frames

  -- Renoise note, fine tune, waveform state, sample key, played pitch and volume of every frame.
  local notes, fines, states, samples, pitches, volumes = {}, {}, {}, {}, {}, {}
  -- Pitch jumps (arpeggios) keep the playing sample: a jump of at least JUMP_SEMITONES with an unchanged waveform state
  -- only changes the note (0GFF) and keeps the fine tune of the playing sample (off by a few cents of the period
  -- table tuning), until the waveform state changes or the pitch moves in small steps (slide). Otherwise every
  -- arpeggio step would be a sample switch, which the PWM crossfade smeared and dipped (xeron - 64k is all you need,
  -- AHX 1 / instrument 02).
  local previous_pitch, sticky_fine = nil, nil
  for index, frame in ipairs(frames) do
    local ahx_note
    if frame.fixed then
      ahx_note = frame.instr_period
    else
      -- The replayer plays `performance note + track note - 1`.
      ahx_note = frame.instr_period + track_ahx_note - 1
    end
    local pitch = clamp(exact_pitch(ahx_note, frame.perf_slide_period), 0, 119)
    pitch = math.floor(pitch * fine_steps + 0.5) / fine_steps
    -- Unrolled frames repeat the simulated loop, so their state index is the one of the simulated frame.
    local simulated_index = index
    if index > simulated_count then
      local loop_length = simulation.loop_end - simulation.loop_start + 1
      simulated_index = simulation.loop_start + (index - simulation.loop_start) % loop_length
    end
    states[index] = state_set.frame_states[simulation_index][simulated_index]

    if index > 1 then
      local jump = math.abs(pitch - previous_pitch)
      if states[index] ~= states[index - 1] or (jump > 0 and jump < JUMP_SEMITONES) then
        sticky_fine = nil
      elseif jump >= JUMP_SEMITONES then
        sticky_fine = fines[index - 1]
      end
    end
    previous_pitch = pitch

    local note, fine
    if sticky_fine then
      fine = sticky_fine
      note = math.floor(pitch - fine / fine_steps + 0.5)
    else
      note = math.floor(pitch + 0.5)
      fine = math.floor((pitch - note) * fine_steps + 0.5)
    end
    notes[index] = note
    fines[index] = fine
    pitches[index] = note + fine / fine_steps
    samples[index] = states[index] .. ':' .. fines[index]
    volumes[index] = frame.volume * 2
  end

  -- Playback position inside the sample buffer (frames), as Renoise plays it.
  local position = 0
  for index = 1, #frames do
    -- Lines are written as changes. The loop start can be reached from the line before it and from the loop end.
    local previous = { index - 1 }
    if index == loop_start then
      previous[#previous + 1] = loop_end
    end

    local note_changed, sample_changed, volume_changed = index == 1, index == 1, index == 1
    for _, other in ipairs(previous) do
      if other >= 1 then
        note_changed = note_changed or notes[other] ~= notes[index]
        sample_changed = sample_changed or samples[other] ~= samples[index]
        volume_changed = volume_changed or volumes[other] ~= volumes[index]
      end
    end

    local line = {}
    if note_changed or sample_changed then
      line.note = notes[index]
      line.sample_key = samples[index]
      line.state_index = states[index]
      line.fine_index = fines[index]
      line.glide = index > 1 and not sample_changed
      if sample_changed and index > 1 then
        local state = state_set.states[states[index]]
        if state.waveform ~= Waves.NOISE then
          -- 0Sxx starts the sample at xx/256 of its length, i.e. at frame xx of the 256-frame buffer (verified by ear).
          line.offset = math.floor(position) % Tables.SAMPLE_BUFFER_LENGTH
          position = line.offset
        else
          position = 0
        end
      end
    end
    -- A note line (also a 0GFF glide) starts at full volume when its volume column is empty, so every note line
    -- carries the current volume (observed in Renoise: the looping noise of the pink - sometimes snare got loud).
    if volume_changed or line.note then
      line.volume = volumes[index]
    end
    if line.note or line.volume then
      data.lines[index] = line
    end

    local rate = SAMPLE_RATE * 2 ^ ((pitches[index] - BASE_NOTE) / 12)
    position = (position + rate / frames_per_second) % Tables.SAMPLE_BUFFER_LENGTH
  end

  if note_off then
    data.lines[#frames + 1] = { note_off = true }
  end

  return data
end

return PhraseBuilder
