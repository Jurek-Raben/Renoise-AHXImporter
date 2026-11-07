-- Creates Renoise instruments from AHX instruments: one sample per waveform state of the simulated notes, and one
-- phrase per triggered note that plays it frame by frame (sample switches, pitch, envelope volume). Triggers with a
-- square offset (9xx) or a following pitch slide get extra variant phrases.

local FilterPath = require('ahx.filter_path')
local NoteUsage = require('ahx.note_usage')
local PhraseBuilder = require('ahx.phrase_builder')
local Simulator = require('ahx.simulator')
local Timing = require('ahx.timing')
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

-- Name prefix of the samples that start the phrases (they have a volume AHDSR of their own, see `ReleaseWriter`).
local START_PREFIX = '[Start] '

-- Fine pitch of the phrases (performance list portamento, period table tuning): 1/16 semitone, coarsened when the
-- waveform state / fine tune pairs do not fit into the 255 addressable samples.
local FINE_STEPS_PER_SEMITONE = 16
local FINE_TUNE_PER_SEMITONE = 128

---Fits the phrases into the phrase limit: the most used variants are kept, and the notes of dropped variants get a
---plain phrase (their triggers play without slide / square offset).
---@param usage AhxInstrumentUsage
---@return AhxInstrumentUsage usage with the kept variants and the needed plain notes
local function fit_phrases(usage)
  for kept = #usage.variants, 0, -1 do
    local notes, seen = {}, {}
    local function add(note)
      if not seen[note] then
        seen[note] = true
        notes[#notes + 1] = note
      end
    end
    for _, note in ipairs(usage.notes) do
      add(note)
    end
    for index = kept + 1, #usage.variants do
      add(usage.variants[index].note)
    end
    if #notes + kept <= MAX_PHRASES then
      table.sort(notes)
      local variants = {}
      for index = 1, kept do
        variants[index] = usage.variants[index]
      end
      return {
        notes = notes,
        variants = variants,
        square_offsets = usage.square_offsets,
        center_note = usage.center_note,
      }
    end
  end
  return usage
end

---Builds the plain phrases (one per note) and the variant phrases (9xx, baked slides) of an instrument.
---@param simulations AhxSimulation[]
---@param state_set AhxWaveStateSet
---@param simulation_by_offset table<integer, integer>
---@param usage AhxInstrumentUsage
---@param frames_per_second number
---@param fine_steps integer
---@return AhxPhraseData[] phrases
---@return { data: AhxPhraseData, variant: AhxNoteVariant }[] variants
local function build_phrases(simulations, state_set, simulation_by_offset, usage, frames_per_second, fine_steps)
  local phrases = {}
  for index, note in ipairs(usage.notes) do
    phrases[index] = PhraseBuilder.build(simulations[1], state_set, 1, note, frames_per_second, fine_steps)
    phrases[index].simulation_index = 1
    ProcessSlicer.step()
  end

  local variants = {}
  for _, variant in ipairs(usage.variants) do
    local simulation_index = variant.square_offset and simulation_by_offset[variant.square_offset] or 1
    variants[#variants + 1] = {
      data = PhraseBuilder.build(
        simulations[simulation_index],
        state_set,
        simulation_index,
        variant.note,
        frames_per_second,
        fine_steps,
        variant.slides
      ),
      variant = variant,
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
---@field first boolean copy for the phrase's first line (note start set)
---@field top_note integer highest note the sample is played at (band limit)
---@field locked boolean|nil belongs to the song: phrases added by the fill up do not change its band limit

---@class AhxSampleCollector
---@field keys AhxSampleKey[] distinct sample keys (waveform state + fine tune) in order of first use
---@field by_key table<string, AhxSampleKey>
---@field phrase_number integer
---@field per_phrase boolean every phrase gets samples of its own (Renoise-filter path: a cutoff envelope per note)
---@field separate_first boolean the sample of a phrase's first line is a copy of its own (marked `first`) with the note
---start set (see `ReleaseWriter.write_start`)
---@field per_octave boolean band-limited rendering: one sample per octave of the played note

---Adds the sample keys of a phrase and rewrites the keys of its lines. When a limit is given and the keys exceed it,
---the collector stays as it was and the phrase is unusable (the fill up then discards it).
---@param collector AhxSampleCollector
---@param data AhxPhraseData
---@param limit integer|nil
---@return boolean added
local function collect_phrase(collector, data, limit)
  local keys, by_key = collector.keys, collector.by_key
  local first_new = #keys + 1
  local previous_top_notes = {}
  collector.phrase_number = collector.phrase_number + 1
  local current = nil
  for index = 1, data.number_of_lines do
    local line = data.lines[index]
    if line and line.sample_key then
      if line.glide and current then
        -- A glide keeps the playing sample (no retrigger).
        line.sample_key = current.key
      else
        if collector.per_phrase then
          line.sample_key = line.state_index .. ':' .. line.fine_index .. '#' .. collector.phrase_number
        end
        if collector.per_octave then
          line.sample_key = line.sample_key .. '@' .. math.floor(line.note / 12)
        end
        local first = collector.separate_first and index == 1
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
      if not current.locked then
        previous_top_notes[current] = previous_top_notes[current] or current.top_note
        current.top_note = math.max(current.top_note, line.note)
      end
    end
  end

  if limit and #keys > limit then
    for index = #keys, first_new, -1 do
      by_key[keys[index].key] = nil
      keys[index] = nil
    end
    for key, top_note in pairs(previous_top_notes) do
      key.top_note = top_note
    end
    return false
  end
  return true
end

---Collects the sample keys of all phrases of the song.
---@param phrases AhxPhraseData[]
---@param variants { data: AhxPhraseData }[]
---@param per_phrase boolean
---@param separate_first boolean
---@param per_octave boolean
---@return AhxSampleCollector
local function collect_sample_keys(phrases, variants, per_phrase, separate_first, per_octave)
  local collector = {
    keys = {},
    by_key = {},
    phrase_number = 0,
    per_phrase = per_phrase,
    separate_first = separate_first,
    per_octave = per_octave,
  }
  for _, data in ipairs(phrases) do
    collect_phrase(collector, data)
  end
  for _, variant in ipairs(variants) do
    collect_phrase(collector, variant.data)
  end
  return collector
end

---Adds playable phrases for the keys the song does not use, from the center note outwards, as long as they fit into the
---free phrase and sample slots. Everything the song needs is already settled and stays as it is: the samples keep their
---indices and band limits, and the fine tune resolution and the note start / crossfade decision do not change. A note
---that does not fit ends its direction, so the playable keys stay without gaps as far as possible.
---A fill note can switch samples although the song's notes do not (the period table is coarser at high notes). It then
---plays without crossfade and note start copies, like the rest of that instrument.
---@param phrases AhxPhraseData[] gets the new phrases and stays sorted by note
---@param variants { data: AhxPhraseData }[]
---@param collector AhxSampleCollector
---@param simulation AhxSimulation the plain note
---@param state_set AhxWaveStateSet
---@param center_note integer
---@param frames_per_second number
---@param fine_steps integer
---@return integer added number of new phrases
local function fill_up(phrases, variants, collector, simulation, state_set, center_note, frames_per_second, fine_steps)
  local taken = {}
  for _, data in ipairs(phrases) do
    taken[data.note] = true
  end
  for _, key in ipairs(collector.keys) do
    key.locked = true
  end

  local added = 0
  local closed = {}
  for _, note in ipairs(NoteUsage.fill_order(center_note)) do
    if #phrases + #variants >= MAX_PHRASES then
      break
    end
    local direction = note < center_note and 'down' or 'up'
    if not taken[note] and not closed[direction] then
      local data = PhraseBuilder.build(simulation, state_set, 1, note, frames_per_second, fine_steps)
      data.simulation_index = 1
      if collect_phrase(collector, data, WaveStates.MAX_STATES) then
        phrases[#phrases + 1] = data
        added = added + 1
      else
        closed[direction] = true
      end
      ProcessSlicer.step()
    end
  end
  table.sort(phrases, function(a, b)
    return a.note < b.note
  end)
  return added
end

---Fills an empty Renoise instrument with an AHX instrument.
---@param target renoise.Instrument
---@param song AhxSong
---@param number integer AHX instrument number (1-based like in AHX)
---@param plan AhxTimingPlan
---@param usage AhxInstrumentUsage
---@param report fun(name: string)
---@param options AhxImportOptions
---@return table<string, integer> variant phrase index by variant key
function InstrumentWriter.write(target, song, number, plan, usage, report, options)
  local instrument = song.instruments[number]
  local variant_count = #usage.variants
  usage = fit_phrases(usage)
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
  local slides = false
  for _, variant in ipairs(usage.variants) do
    slides = slides or variant.slides ~= nil
  end
  local filter_side = FilterPath.analyze(simulations, instrument.wave_length, slides)
  local state_set = WaveStates.collect(simulations, instrument.wave_length, filter_side ~= nil)
  local frames_per_second = Timing.frames_per_second(plan)
  if filter_side then
    Util.log('%s: %s-pass filter sweep via Renoise filter', name, filter_side)
  end

  -- Phrases first: they decide which waveform state / fine tune pairs are needed as samples. When there are more
  -- pairs than the phrase instrument column can address, the fine tune gets coarser.
  local fine_steps = FINE_STEPS_PER_SEMITONE
  local phrases, variants, collector, crossfade_ms, switching
  local band_limited = options.rendering == 3
  local per_octave = band_limited
  while true do
    phrases, variants =
      build_phrases(simulations, state_set, simulation_by_offset, usage, frames_per_second, fine_steps)
    -- Phrases that switch samples start with a copy of their first sample, which gets a modulation set of its own
    -- (note start AHDSR, see `ReleaseWriter`); otherwise every sample starts a phrase.
    switching = not filter_side and phrases_switch_samples(phrases, variants)
    -- The PWM crossfade only matters for phrases that switch samples; instruments with hard cut release keep their
    -- own release (see `ReleaseWriter`).
    crossfade_ms = 0
    if
      options.crossfade_ms > 0
      and switching
      and not (instrument.hard_cut_release ~= 0 and instrument.hard_cut_release_frames > 0)
    then
      crossfade_ms = options.crossfade_ms
    end
    collector = collect_sample_keys(phrases, variants, filter_side ~= nil, switching, per_octave)
    if #collector.keys <= WaveStates.MAX_STATES then
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
  if #variants < variant_count then
    report('variant phrases beyond the phrase limit (played without slide / 9xx)')
  end
  if fine_steps < FINE_STEPS_PER_SEMITONE then
    report('fine pitch resolution reduced (too many waveform states)')
  end

  if options.fill_notes then
    ProcessSlicer.step(('Instrument %02d: filling up with notes'):format(number))
    local added = fill_up(
      phrases,
      variants,
      collector,
      simulations[1],
      state_set,
      usage.center_note,
      frames_per_second,
      fine_steps
    )
    Util.log(
      '%s: filled up with %d notes around %s (%d playable keys, %s..%s, %d samples)',
      name,
      added,
      PhraseWriter.note_name(usage.center_note),
      #phrases,
      PhraseWriter.note_name(phrases[1].note),
      PhraseWriter.note_name(phrases[#phrases].note),
      #collector.keys
    )
  end
  local sample_keys = collector.keys

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
    if key.first or not switching then
      sample_name = START_PREFIX .. sample_name
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
  ReleaseWriter.write(target, instrument, frames_per_second, crossfade_ms, report)
  if options.crossfade_ms > 0 and instrument.hard_cut_release ~= 0 and instrument.hard_cut_release_frames > 0 then
    report('PWM crossfade (skipped for instruments with hard cut release)')
  end
  -- Before the Renoise-filter path: its sets start as copies of set 1, so they carry the note start AHDSR.
  local start_samples = {}
  for index, key in ipairs(sample_keys) do
    if key.first then
      start_samples[#start_samples + 1] = target.samples[index]
    end
  end
  ReleaseWriter.write_start(target, switching, start_samples, report)
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
---@param usage table<integer, AhxInstrumentUsage> notes and variants per AHX instrument number (`NoteUsage`)
---@return table<integer, table<string, integer>> variant phrase indices by AHX instrument number
function InstrumentWriter.write_all(song, plan, report, options, usage)
  local rns = renoise.song()
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
