-- Writes neutral phrase data into Renoise instrument phrases: one phrase per triggered note, each mapped to exactly
-- that key and played without key tracking (the phrase holds absolute pitches).

local ProcessSlicer = require('importer.process_slicer')

local PhraseWriter = {}

local NOTE_NAMES = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }

---@param note integer 0..119
---@return string
local function note_name(note)
  return NOTE_NAMES[note % 12 + 1] .. math.floor(note / 12)
end

PhraseWriter.note_name = note_name

---@param phrase renoise.InstrumentPhrase
---@param data AhxPhraseData
local function write_lines(phrase, data)
  for index, line_data in pairs(data.lines) do
    local line = phrase:line(index)
    local column = line.note_columns[1]
    if line_data.note_off then
      column.note_string = 'OFF'
    elseif line_data.note then
      column.note_value = line_data.note
      column.instrument_value = line_data.instrument
      if line_data.glide then
        -- 0GFF glides instantly: the pitch changes without retriggering the sample.
        line.effect_columns[1].number_string = '0G'
        line.effect_columns[1].amount_value = 0xff
      elseif line_data.offset and line_data.offset > 0 then
        line.effect_columns[1].number_string = '0S'
        line.effect_columns[1].amount_value = line_data.offset
      end
    end
    if line_data.volume then
      column.volume_value = line_data.volume
    end
  end
end

---@param instrument renoise.Instrument
---@param index integer
---@param data AhxPhraseData
---@param phrase_lpb integer
---@param name string
---@return renoise.InstrumentPhrase
local function insert_phrase(instrument, index, data, phrase_lpb, name)
  local phrase = instrument:insert_phrase_at(index)
  phrase.name = name
  phrase.number_of_lines = data.number_of_lines
  phrase.lpb = phrase_lpb
  phrase.instrument_column_visible = true
  phrase.volume_column_visible = true
  phrase.visible_effect_columns = 1
  phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE

  write_lines(phrase, data)

  if data.loop_start and data.loop_end then
    phrase.looping = true
    phrase.loop_end = data.loop_end
    phrase.loop_start = data.loop_start
  else
    phrase.looping = false
  end
  return phrase
end

---Creates one keymapped phrase per triggered note, followed by unmapped variant phrases (9xx square offset and/or
---baked pitch slide) that the pattern selects with 0Zxx.
---@param instrument renoise.Instrument
---@param phrases AhxPhraseData[] sorted by note
---@param variants { data: AhxPhraseData, variant: AhxNoteVariant }[]
---@param phrase_lpb integer
---@param name string
---@return table<string, integer> phrase index by variant key
function PhraseWriter.write(instrument, phrases, variants, phrase_lpb, name)
  instrument.phrase_playback_mode = renoise.Instrument.PHRASES_PLAY_KEYMAP

  for index, data in ipairs(phrases) do
    local phrase = insert_phrase(instrument, index, data, phrase_lpb, ('%s %s'):format(name, note_name(data.note)))

    -- Mappings are sorted by note and may not overlap: each new mapping first takes the whole free range behind the
    -- previous one, then gets narrowed to its single key.
    local mapping = instrument:insert_phrase_mapping_at(index, phrase)
    mapping.note_range = { data.note, data.note }
    mapping.key_tracking = renoise.InstrumentPhraseMapping.KEY_TRACKING_NONE

    ProcessSlicer.step(('%s: phrase %s'):format(name, note_name(data.note)))
  end

  local variant_index = {}
  for offset, entry in ipairs(variants) do
    local index = #phrases + offset
    local data, variant = entry.data, entry.variant
    local label = note_name(data.note)
    if variant.square_offset then
      label = ('%s 9%02X'):format(label, variant.square_offset)
    end
    if variant.slides then
      label = label .. ' slide'
    end
    insert_phrase(instrument, index, data, phrase_lpb, ('%s %s'):format(name, label))
    variant_index[variant.key] = index
    ProcessSlicer.step(('%s: phrase %s'):format(name, label))
  end
  return variant_index
end

return PhraseWriter
