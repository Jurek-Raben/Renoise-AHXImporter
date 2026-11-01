-- Creates Renoise instruments from AHX instruments: one sample per waveform state of the simulated notes, and one
-- phrase per triggered note that plays it frame by frame (sample switches, pitch, envelope volume). Triggers with a
-- square offset (9xx) get extra variant phrases.

local NoteUsage = require('ahx.note_usage')
local PhraseBuilder = require('ahx.phrase_builder')
local Simulator = require('ahx.simulator')
local WaveStates = require('ahx.wave_states')
local Waves = require('ahx.waves')
local PhraseWriter = require('importer.phrase_writer')
local ProcessSlicer = require('importer.process_slicer')
local ReleaseWriter = require('importer.release_writer')
local SampleWriter = require('importer.sample_writer')

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
    ProcessSlicer.step()
  end
  return phrases, variants
end

---Distinct sample keys (waveform state + fine tune) of all phrases, in order of first use.
---@param phrases AhxPhraseData[]
---@param variants { data: AhxPhraseData }[]
---@return { key: string, state_index: integer, fine_index: integer }[]
local function collect_sample_keys(phrases, variants)
  local keys, seen = {}, {}
  local function collect(data)
    for index = 1, data.number_of_lines do
      local line = data.lines[index]
      if line and line.sample_key and not seen[line.sample_key] then
        seen[line.sample_key] = true
        keys[#keys + 1] = { key = line.sample_key, state_index = line.state_index, fine_index = line.fine_index }
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
  local state_set = WaveStates.collect(simulations, instrument.wave_length)
  local frames_per_second = 50 * plan.speed_multiplier

  -- Phrases first: they decide which waveform state / fine tune pairs are needed as samples. When there are more
  -- pairs than the phrase instrument column can address, the fine tune gets coarser.
  local fine_steps = FINE_STEPS_PER_SEMITONE
  local phrases, variants, sample_keys
  while true do
    phrases, variants =
      build_phrases(simulations, state_set, simulation_by_offset, usage, frames_per_second, fine_steps)
    sample_keys = collect_sample_keys(phrases, variants)
    if #sample_keys <= WaveStates.MAX_STATES or fine_steps == 1 then
      break
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
    local frames = Waves.voice_buffer(state.waveform, state.filter_pos, state.wave_length, state.square_pos)

    local sample = target:insert_sample_at(index)
    local sample_name = WaveStates.describe(state)
    if key.fine_index ~= 0 then
      sample_name = ('%s %+d/%d'):format(sample_name, key.fine_index, fine_steps)
    end
    SampleWriter.write(sample, frames, sample_name, options)
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
  ReleaseWriter.write(target, instrument, frames_per_second, report)
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
