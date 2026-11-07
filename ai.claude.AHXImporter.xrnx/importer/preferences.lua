-- Import options in preferences.xml in the tool folder. The document is not assigned to `renoise.tool().preferences`:
-- Renoise would then write it back on its own (e.g. when the tool unloads). The file is read once here and written
-- only by `Preferences.save` (the options dialog's Save button).

local Tables = require('ahx.tables')
local Util = require('importer.util')

local Preferences = {}

Preferences.INTERPOLATIONS = { 'None', 'Linear', 'Cubic', 'Sinc' }
Preferences.BIT_DEPTHS = { 8, 16, 32 }
Preferences.SAMPLE_RATE_FACTORS = { 1, 2, 4 }
-- Index 1 = original (every frame repeated), 2 = smoothed (cubic interpolation between the frames), 3 = band-limited
-- (cycles resynthesized without the harmonics that would alias at the played pitch).
Preferences.RENDERINGS = { 'Original', 'Smoothed', 'Band-limited' }
-- 0 = automatic (see `Resolution.auto`).
Preferences.LINES_PER_ROW = { 0, 1, 2, 4 }
Preferences.MAX_FILTER_RESONANCE = 0.3
Preferences.DEFAULT_FILTER_RESONANCE = 0.136
Preferences.DEFAULT_ROLL_OFF = 0.5
Preferences.MAX_CROSSFADE_MS = 80
Preferences.DEFAULT_CROSSFADE_MS = 10

local document = renoise.Document.create('AHXImporterPreferences') {
  -- Index into INTERPOLATIONS, equal to renoise.Sample.INTERPOLATE_* (1 = none).
  interpolation = 4,
  -- Renoise's sample option "Oversample" (band-limited playback of the interpolation).
  oversample = false,
  bit_depth = 32,
  sample_rate_factor = 4,
  rendering = 2,
  filter_resonance = Preferences.DEFAULT_FILTER_RESONANCE,
  lines_per_row = 0,
  crossfade_ms = Preferences.DEFAULT_CROSSFADE_MS,
  band_limit_roll_off = Preferences.DEFAULT_ROLL_OFF,
  fill_notes = true,
  -- Index into Tables.TUNINGS.
  tuning = Tables.DEFAULT_TUNING,
}

-- ASSUMPTION: bundle_path ends with a path separator (handled either way).
local bundle_path = renoise.tool().bundle_path
if not bundle_path:match('[/\\]$') then
  bundle_path = bundle_path .. '/'
end
local FILE_NAME = bundle_path .. 'preferences.xml'

local existing = io.open(FILE_NAME, 'r')
if existing then
  existing:close()
  local ok, error_message = document:load_from(FILE_NAME)
  if not ok then
    Util.log('could not load %s: %s', FILE_NAME, tostring(error_message))
  end
end

---@class AhxImportOptions
---@field interpolation integer renoise.Sample.INTERPOLATE_* (1..4)
---@field oversample boolean sample option "Oversample"
---@field bit_depth integer 8, 16 or 32
---@field sample_rate_factor integer 1, 2 or 4 (multiple of the base rate of the tuning)
---@field tuning integer index into `Tables.TUNINGS`
---@field rendering integer 1 = original, 2 = smoothed, 3 = band-limited (see Preferences.RENDERINGS)
---@field lines_per_row integer 0 (auto), 1, 2 or 4 pattern lines per AHX row (pattern resolution)
---@field band_limit_roll_off number 0..1 share of the harmonics that fades out in band-limited rendering
---@field crossfade_ms integer 0..80 ms crossfade of phrase sample switches (0 = off)
---@field filter_resonance number 0..0.3, resonance of the Renoise filter path (share of the parameter range)
---@field fill_notes boolean free phrase and sample slots get playable notes around the notes the song uses
---@field target_bpm number|nil song BPM of this import, nil = the song's own (depends on the song, so never saved)

---The saved options.
---@return AhxImportOptions
function Preferences.load()
  return {
    interpolation = document.interpolation.value,
    oversample = document.oversample.value,
    bit_depth = document.bit_depth.value,
    sample_rate_factor = document.sample_rate_factor.value,
    rendering = document.rendering.value,
    filter_resonance = document.filter_resonance.value,
    lines_per_row = document.lines_per_row.value,
    crossfade_ms = document.crossfade_ms.value,
    band_limit_roll_off = document.band_limit_roll_off.value,
    fill_notes = document.fill_notes.value,
    tuning = document.tuning.value,
  }
end

---Saves options to preferences.xml.
---@param options AhxImportOptions
function Preferences.save(options)
  document.interpolation.value = options.interpolation
  document.oversample.value = options.oversample
  document.bit_depth.value = options.bit_depth
  document.sample_rate_factor.value = options.sample_rate_factor
  document.rendering.value = options.rendering
  document.filter_resonance.value = options.filter_resonance
  document.lines_per_row.value = options.lines_per_row
  document.crossfade_ms.value = options.crossfade_ms
  document.band_limit_roll_off.value = options.band_limit_roll_off
  document.fill_notes.value = options.fill_notes
  document.tuning.value = options.tuning
  local ok, error_message = document:save_as(FILE_NAME)
  if not ok then
    Util.log('could not save %s: %s', FILE_NAME, tostring(error_message))
  end
end

---@param options AhxImportOptions
---@return boolean
function Preferences.is_saved(options)
  local saved = Preferences.load()
  return saved.interpolation == options.interpolation
      and saved.oversample == options.oversample
      and saved.bit_depth == options.bit_depth
      and saved.sample_rate_factor == options.sample_rate_factor
      and saved.rendering == options.rendering
      and math.abs(saved.filter_resonance - options.filter_resonance) < 0.0005
      and saved.lines_per_row == options.lines_per_row
      and saved.crossfade_ms == options.crossfade_ms
      and math.abs(saved.band_limit_roll_off - options.band_limit_roll_off) < 0.005
      and saved.fill_notes == options.fill_notes
      and saved.tuning == options.tuning
end

return Preferences
