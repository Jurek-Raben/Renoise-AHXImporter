-- Import options. Renoise loads/saves them automatically (preferences.xml in the tool folder). The options dialog
-- edits a copy and writes it back only with its Save button.

local Preferences = {}

Preferences.INTERPOLATIONS = { 'None', 'Linear', 'Cubic', 'Sinc' }
Preferences.BIT_DEPTHS = { 8, 16, 32 }
Preferences.SAMPLE_RATE_FACTORS = { 1, 2, 4 }
-- 0 = automatic (see `Resolution.auto`).
Preferences.LINES_PER_ROW = { 0, 1, 2, 4 }
Preferences.MAX_FILTER_RESONANCE = 0.3
Preferences.DEFAULT_FILTER_RESONANCE = 0.15
Preferences.MAX_CROSSFADE_MS = 20
Preferences.DEFAULT_CROSSFADE_MS = 10

local document = renoise.Document.create('AHXImporterPreferences') {
  -- Index into INTERPOLATIONS, equal to renoise.Sample.INTERPOLATE_* (1 = none).
  interpolation = 1,
  bit_depth = 8,
  sample_rate_factor = 1,
  filter_resonance = Preferences.DEFAULT_FILTER_RESONANCE,
  lines_per_row = 0,
  crossfade_ms = Preferences.DEFAULT_CROSSFADE_MS,
}

renoise.tool().preferences = document

---@class AhxImportOptions
---@field interpolation integer renoise.Sample.INTERPOLATE_* (1..4)
---@field bit_depth integer 8, 16 or 32
---@field sample_rate_factor integer 1, 2 or 4 (multiple of the base rate 8363 Hz)
---@field lines_per_row integer 0 (auto), 1, 2 or 4 pattern lines per AHX row (pattern resolution)
---@field crossfade_ms integer 0..20 ms crossfade of phrase sample switches (0 = off)
---@field filter_resonance number 0..0.3, resonance of the Renoise filter path (share of the parameter range)

---The saved options.
---@return AhxImportOptions
function Preferences.load()
  return {
    interpolation = document.interpolation.value,
    bit_depth = document.bit_depth.value,
    sample_rate_factor = document.sample_rate_factor.value,
    filter_resonance = document.filter_resonance.value,
    lines_per_row = document.lines_per_row.value,
    crossfade_ms = document.crossfade_ms.value,
  }
end

---Saves options.
---@param options AhxImportOptions
function Preferences.save(options)
  document.interpolation.value = options.interpolation
  document.bit_depth.value = options.bit_depth
  document.sample_rate_factor.value = options.sample_rate_factor
  document.filter_resonance.value = options.filter_resonance
  document.lines_per_row.value = options.lines_per_row
  document.crossfade_ms.value = options.crossfade_ms
end

---@param options AhxImportOptions
---@return boolean
function Preferences.is_saved(options)
  local saved = Preferences.load()
  return saved.interpolation == options.interpolation
      and saved.bit_depth == options.bit_depth
      and saved.sample_rate_factor == options.sample_rate_factor
      and math.abs(saved.filter_resonance - options.filter_resonance) < 0.0005
      and saved.lines_per_row == options.lines_per_row
      and saved.crossfade_ms == options.crossfade_ms
end

return Preferences
