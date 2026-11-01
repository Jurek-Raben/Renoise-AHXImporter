-- Import options. Renoise loads/saves them automatically (preferences.xml in the tool folder). The options dialog
-- edits a copy and writes it back only with its Save button.

local Preferences = {}

Preferences.INTERPOLATIONS = { 'None', 'Linear', 'Cubic', 'Sinc' }
Preferences.BIT_DEPTHS = { 8, 16, 32 }
Preferences.SAMPLE_RATE_FACTORS = { 1, 2, 4 }

local document = renoise.Document.create('AHXImporterPreferences') {
  -- Index into INTERPOLATIONS, equal to renoise.Sample.INTERPOLATE_* (1 = none).
  interpolation = 1,
  bit_depth = 8,
  sample_rate_factor = 1,
}

renoise.tool().preferences = document

---@class AhxImportOptions
---@field interpolation integer renoise.Sample.INTERPOLATE_* (1..4)
---@field bit_depth integer 8, 16 or 32
---@field sample_rate_factor integer 1, 2 or 4 (multiple of the base rate 8363 Hz)

---The saved options.
---@return AhxImportOptions
function Preferences.load()
  return {
    interpolation = document.interpolation.value,
    bit_depth = document.bit_depth.value,
    sample_rate_factor = document.sample_rate_factor.value,
  }
end

---Saves options.
---@param options AhxImportOptions
function Preferences.save(options)
  document.interpolation.value = options.interpolation
  document.bit_depth.value = options.bit_depth
  document.sample_rate_factor.value = options.sample_rate_factor
end

---@param options AhxImportOptions
---@return boolean
function Preferences.is_saved(options)
  local saved = Preferences.load()
  return saved.interpolation == options.interpolation
    and saved.bit_depth == options.bit_depth
    and saved.sample_rate_factor == options.sample_rate_factor
end

return Preferences
