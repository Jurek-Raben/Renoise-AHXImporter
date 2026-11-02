-- Creates Renoise instruments from AHX instruments: one sample per waveform state of the simulated notes, and one
-- phrase per triggered note that plays it frame by frame (sample switches, pitch, envelope volume). Triggers with a
-- square offset (9xx) get extra variant phrases.

local FilterPath = require('ahx.filter_path')
local NoteUsage = require('ahx.note_usage')
local PhraseBuilder = require('ahx.phrase_builder')
local Simulator = require('ahx.simulator')
local WaveStates = require('ahx.wave_states')
local Waves = require('ahx.waves')
local FilterWriter = require('importer.filter_writer')
local PhraseWriter = require('importer.phrase_writer')
local ProcessSlicer = require('importer.process_slicer')
local ReleaseWriter = require('importer.release_writer')
local SampleWriter = require('importer.sample_writer')
local Util = require('importer.util')

local InstrumentWriter = {}

-- Default instrument volume: four full-scale chip voices easily clip the master otherwise.
local INSTRUMENT_VOLUME_DB = -6

-- An instrument has at most 126 phrases.
local MAX_PHRASES = 126

-- Fine pitch of the phrases (performance list portamento, period table tuning): 1/16 semitone, coarsened when the
-- waveform state / fine tune pairs do not fit into the 255 addressable samples.
local FINE_STEPS_PER_SEMITONE = 16
local FINE_TUNE_PER_SEMITONE = 128

---Builds the plain phrases (one per note) and the 9xx variant phrases of an instrument.
---@param simulations AhxSimulation[]
---@param state_set AhxWaveStateSet
---@param simulation_by_offset table<integer, integer>
---@param usage AhxInstrumentUsage
---@param frames_per_second number
---@param fine_steps integer
---@return AhxPhraseData[] phrases
---@return { data: AhxPhraseData, square_offset: integer }[] variants
local function build_phrases(simulations, state_set, simulation_by_offset, usage, frames_per_second, fine_steps)
  local phrases = {}
  for index, note in ipairs(usage.notes) do
    phrases[index] = PhraseBuilder.build(simulations[1], state_set, 1, note, frames_per_second, fine_steps)
    phrases[index].simulation_index = 1
    ProcessSlicer.step()
  end

  local variants = {}
  for _, variant in ipairs(usage.variants) do
    if #phrases + #variants >= MAX_PHRASES then
      break
    end
    local simulation_index = simulation_by_offset[variant.square_offset]
    variants[#variants + 1] = {
      data = PhraseBuilder.build(
        simulations[simulation_index],
        state_set,
        simulation_index,
        variant.note,
        frames_per_second,
        fine_steps
      ),
      square_offset = variant.square_offset,
    }
    variants[#variants].data.simulation_index = simulation_index
    ProcessSlicer.step()
  end
  return phrases, variants
end

---True when a phrase switches between samples during the note.
---@param phrases AhxPhraseData[]
---@param variants { data: AhxPhraseData }[]
---@return boolean
local function phrases_switch_samples(phrases, variants)
  local function switches(data)
    local first = nil
    for index = 1, data.number_of_lines do
      local line = data.lines[index]
      if line and line.sample_key then
        first = first or line.sample_key
        if line.sample_key ~= first then
          return true
        end
      end
    end
    return false
  end
  for _, data in ipairs(phrases) do
    if switches(data) then
      return true
    end
  end
  for _, variant in ipairs(variants) do
    if switches(variant.data) then
      return true
    end
  end
  return false
end

---@class AhxSampleKey
---@field key string
---@field state_index integer
---@field fine_index integer
---@field phrase AhxPhraseData first phrase that uses the sample
---@field first boolean copy for the phrase's first line (no fade-in)
---@field top_note integer highest note the sample is played at (band limit)

---Distinct sample keys (waveform state + fine tune) of all phrases, in order of first use. With `per_phrase`, every
---phrase gets samples of its own (the Renoise-filter path needs a cutoff envelope per note). With `separate_first`,
---the sample of a phrase's first line is a copy of its own (marked `first`), so the PWM crossfade can leave the note
---start without fade-in.
---@param phrases AhxPhraseData[]
---@param variants { data: AhxPhraseData }[]
---@param per_phrase boolean
---@param separate_first boolean
---@param per_octave boolean band-limited rendering: one sample per octave of the played note
---@return AhxSampleKey[]
local function collect_sample_keys(phrases, variants, per_phrase, separate_first, per_octave)
  local keys, by_key = {}, {}
  local phrase_number = 0
  local function collect(data)
    phrase_number = phrase_number + 1
    local current = nil
    for index = 1, data.number_of_lines do
      local line = data.lines[index]
      if line and line.sample_key then
        if line.glide and current then
          -- A glide keeps the playing sample (no retrigger).
          line.sample_key = current.key
        else
          if per_phrase then
            line.sample_key = line.state_index .. ':' .. line.fine_index .. '#' .. phrase_number
          end
          if per_octave then
            line.sample_key = line.sample_key .. '@' .. math.floor(line.note / 12)
          end
          local first = separate_first and index == 1
          if first then
            line.sample_key = line.sample_key .. '|first'
          end
          current = by_key[line.sample_key]
          if not current then
            current = {
              key = line.sample_key,
              state_index = line.state_index,
              fine_index = line.fine_index,
              phrase = data,
              first = first,
              top_note = line.note,
            }
            by_key[line.sample_key] = current
            keys[#keys + 1] = current
          end
        end
        -- Highest note the sample is played at (band limit).
        current.top_note = math.max(current.top_note, line.note)
      end
    end
  end
  for _, data in ipairs(phrases) do
    collect(data)
  end
  for _, variant in ipairs(variants) do
    collect(variant.data)
  end
  return keys
end

---Fills an empty Renoise instrument with an AHX instrument.
---@param target renoise.Instrument
---@param song AhxSong
---@param number integer AHX instrument number (1-based like in AHX)
---@param plan AhxTimingPlan
---@param usage AhxInstrumentUsage
---@param report fun(name: string)
---@param options AhxImportOptions
---@return table<string, integer> variant phrase index by `square_offset .. ':' .. note`
function InstrumentWriter.write(target, song, number, plan, usage, report, options)
  local instrument = song.instruments[number]
  local name = ('AHX %02d %s'):format(number, instrument.name)

  -- Simulation 1 is the plain note, the others start with a 9xx square offset.
  local simulations = { Simulator.run(song, instrument) }
  local simulation_by_offset = {}
  for _, offset in ipairs(usage.square_offsets) do
    simulations[#simulations + 1] = Simulator.run(song, instrument, { square_offset = offset })
    simulation_by_offset[offset] = #simulations
  end
  -- Renoise-filter path: a one-sided filter sweep without other sample changes is done by the Renoise filter, so the
  -- states are collected unfiltered (see `FilterPath`).
  local filter_side = FilterPath.analyze(simulations, instrument.wave_length)
  local state_set = WaveStates.collect(simulations, instrument.wave_length, filter_side ~= nil)
  local frames_per_second = 50 * plan.speed_multiplier
  if filter_side then
    Util.log('%s: %s-pass filter sweep via Renoise filter', name, filter_side)
  end

  -- Phrases first: they decide which waveform state / fine tune pairs are needed as samples. When there are more
  -- pairs than the phrase instrument column can address, the fine tune gets coarser.
  local fine_steps = FINE_STEPS_PER_SEMITONE
  local phrases, variants, sample_keys, crossfade_ms
  local band_limited = options.rendering == 3
  local per_octave = band_limited
  while true do
    phrases, variants =
      build_phrases(simulations, state_set, simulation_by_offset, usage, frames_per_second, fine_steps)
    -- The PWM crossfade only matters for phrases that switch samples; instruments with hard cut release keep their
    -- own release (see `ReleaseWriter`).
    crossfade_ms = 0
    if
      options.crossfade_ms > 0
      and not filter_side
      and not (instrument.hard_cut_release ~= 0 and instrument.hard_cut_release_frames > 0)
      and phrases_switch_samples(phrases, variants)
    then
      crossfade_ms = options.crossfade_ms
    end
    sample_keys = collect_sample_keys(phrases, variants, filter_side ~= nil, crossfade_ms > 0, per_octave)
    if #sample_keys <= WaveStates.MAX_STATES then
      break
    end
    if fine_steps == 1 then
      if not per_octave then
        break
      end
      -- Band-limited per octave does not fit: one band limit per sample (for its highest note) instead.
      per_octave = false
      fine_steps = FINE_STEPS_PER_SEMITONE * 2
      report('band-limited rendering per octave reduced (too many samples)')
    end
    fine_steps = fine_steps / 2
    ProcessSlicer.step(('Instrument %02d: reducing fine tune'):format(number))
  end
  if #variants < #usage.variants then
    report('9xx variants beyond the phrase limit (played without offset)')
  end
  if fine_steps < FINE_STEPS_PER_SEMITONE then
    report('fine pitch resolution reduced (too many waveform states)')
  end

  target:clear()
  target.name = name
  target.volume = math.db2lin(INSTRUMENT_VOLUME_DB)

  local sample_index = {}
  for index, key in ipairs(sample_keys) do
    local state = state_set.states[key.state_index]

    local sample = target:insert_sample_at(index)
    local sample_name = WaveStates.describe(state)
    if key.fine_index ~= 0 then
      sample_name = ('%s %+d/%d'):format(sample_name, key.fine_index, fine_steps)
    end
    if key.first then
      sample_name = sample_name .. ' (start)'
    end
    if band_limited and state.waveform ~= Waves.NOISE and state.wave_length <= 5 then
      local cycle = Waves.cycle(state.waveform, state.filter_pos, state.wave_length, state.square_pos)
      SampleWriter.write_band_limited(sample, cycle, key.top_note + key.fine_index / fine_steps, sample_name, options)
    else
      local frames = Waves.voice_buffer(state.waveform, state.filter_pos, state.wave_length, state.square_pos)
      SampleWriter.write(sample, frames, sample_name, options)
    end
    -- sample.fine_tune has 128 steps per semitone (verified).
    sample.fine_tune = math.floor(key.fine_index * FINE_TUNE_PER_SEMITONE / fine_steps + 0.5)
    -- The note volume is the channel volume of the pattern (0Mxx), the envelope comes from the phrase.
    sample.volume = 1

    -- The phrase selects the samples. From the keyboard without phrase, only the first state plays: the others use
    -- velocity 0..0, which is not triggered as long as "Vel->Vol" stays enabled in the keyzone.
    -- The keyzone velocity range does not affect samples triggered by the phrase's instrument column (verified).
    local mapping = sample.sample_mapping
    mapping.note_range = { 0, 119 }
    mapping.velocity_range = index == 1 and { 0, 127 } or { 0, 0 }
    mapping.map_velocity_to_volume = true

    sample_index[key.key] = index
    ProcessSlicer.step(('Instrument %02d: %s'):format(number, sample.name))
  end

  -- Sample keys -> 0-based sample indices of the instrument column.
  local function resolve(data)
    for _, line in pairs(data.lines) do
      if line.sample_key then
        line.instrument = sample_index[line.sample_key] - 1
      end
    end
  end
  for _, data in ipairs(phrases) do
    resolve(data)
  end
  for _, variant in ipairs(variants) do
    resolve(variant.data)
  end

  local variant_index = PhraseWriter.write(target, phrases, variants, plan.phrase_lpb, name)

  if state_set.filter_step > 1 then
    report('filter resolution reduced (more than 255 waveform states)')
  end
  if ReleaseWriter.write(target, instrument, frames_per_second, crossfade_ms, report) then
    local first_samples = {}
    for index, key in ipairs(sample_keys) do
      if key.first then
        first_samples[#first_samples + 1] = target.samples[index]
      end
    end
    ReleaseWriter.write_start_set(target, first_samples, report)
  elseif options.crossfade_ms > 0 and instrument.hard_cut_release ~= 0 and instrument.hard_cut_release_frames > 0 then
    report('PWM crossfade (skipped for instruments with hard cut release)')
  end
  if filter_side then
    for index, key in ipairs(sample_keys) do
      local phrase = key.phrase
      local envelope = FilterPath.envelope(simulations[phrase.simulation_index], filter_side, phrase.note)
      FilterWriter.write(
        target,
        target.samples[index],
        filter_side,
        envelope,
        frames_per_second,
        options.filter_resonance,
        report,
        index == 1
      )
      ProcessSlicer.step(('Instrument %02d: filter %d of %d'):format(number, index, #sample_keys))
    end
  end
  return variant_index
end

---Writes all instruments of an AHX song into the current Renoise song. AHX instrument n becomes Renoise instrument n;
---the song's existing first instrument is reused, so no empty slots are left.
---@param song AhxSong
---@param plan AhxTimingPlan
---@param report fun(name: string) collects features that are not converted (yet)
---@param options AhxImportOptions
---@return table<integer, table<string, integer>> variant phrase indices by AHX instrument number
function InstrumentWriter.write_all(song, plan, report, options)
  local rns = renoise.song()
  local usage = NoteUsage.scan(song)
  local variant_phrases = {}

  for number = 1, song.instrument_count do
    if number > #rns.instruments then
      rns:insert_instrument_at(number)
    end
    variant_phrases[number] =
      InstrumentWriter.write(rns.instruments[number], song, number, plan, usage[number], report, options)
  end
  return variant_phrases
end

return InstrumentWriter
