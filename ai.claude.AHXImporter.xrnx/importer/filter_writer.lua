-- Writes the Renoise-filter path (see `FilterPath`): a low- or high-pass filter in every modulation set of the
-- instrument, with the cutoff input driven by the filter macro (macro 2 "Cutoff" of the template, automated per frame
-- by the pattern, see `MacroWriter`). The cutoff is computed in Hz and mapped onto the input by probing its value
-- strings.

local Util = require('importer.util')

local FilterWriter = {}

local LOW_PASS_TYPES = { 'LP 2 Pole', 'LP Clean', 'LP -12 dB' }
local HIGH_PASS_TYPES = { 'HP 2 Pole', 'HP Clean', 'HP -12 dB' }

-- Fallback when the cutoff parameter does not show Hz: logarithmic 20 Hz .. 20 kHz.
local FALLBACK_MIN_HZ = 20
local FALLBACK_MAX_HZ = 20000

local PROBE_STEPS = 200

---@param types string[] available filter types
---@param preferred string[]
---@param prefix string
---@return string|nil
local function pick_filter_type(types, preferred, prefix)
  for _, wanted in ipairs(preferred) do
    for _, name in ipairs(types) do
      if name == wanted then
        return name
      end
    end
  end
  for _, name in ipairs(types) do
    if name:sub(1, #prefix) == prefix then
      return name
    end
  end
  return nil
end

---@param text string e.g. '1.25 kHz', '440 Hz'
---@return number|nil
local function parse_hz(text)
  local number, unit = text:match('([%d%.]+)%s*(%a*)')
  number = tonumber(number)
  if not number then
    return nil
  end
  unit = (unit or ''):lower()
  if unit == 'khz' then
    return number * 1000
  elseif unit == 'hz' then
    return number
  end
  return nil
end

---Maps Hz to the cutoff as 0..1 of the parameter range (= the cutoff macro value), by probing the parameter's
---value strings (restored afterwards).
---@param parameter renoise.DeviceParameter
---@return fun(hz: number): number to_value 0..1
---@return string description
local function cutoff_mapping(parameter)
  local original = parameter.value
  local table_hz, table_value = {}, {}
  local low, high = parameter.value_min, parameter.value_max
  for index = 0, PROBE_STEPS do
    local value = low + (high - low) * index / PROBE_STEPS
    parameter.value = value
    local hz = parse_hz(parameter.value_string)
    if hz then
      table_hz[#table_hz + 1] = hz
      table_value[#table_value + 1] = value
    end
  end
  parameter.value = original

  local range = high - low
  local function normalized(value)
    return math.max(0, math.min(1, (value - low) / range))
  end
  local description = ('range %s..%s'):format(tostring(low), tostring(high))

  if #table_hz < 2 or table_hz[#table_hz] <= table_hz[1] then
    return function(hz)
      local position = math.log(math.max(FALLBACK_MIN_HZ, hz) / FALLBACK_MIN_HZ)
        / math.log(FALLBACK_MAX_HZ / FALLBACK_MIN_HZ)
      return math.max(0, math.min(1, position))
    end, ('%s, fallback 20 Hz..20 kHz (value string "%s")'):format(description, parameter.value_string)
  end

  return function(hz)
    if hz <= table_hz[1] then
      return normalized(table_value[1])
    end
    for index = 2, #table_hz do
      if hz <= table_hz[index] then
        local share = (hz - table_hz[index - 1]) / (table_hz[index] - table_hz[index - 1])
        return normalized(table_value[index - 1] + (table_value[index] - table_value[index - 1]) * share)
      end
    end
    return normalized(table_value[#table_value])
  end, ('%s, probed %.0f Hz..%.0f Hz'):format(description, table_hz[1], table_hz[#table_hz])
end

---@class AhxFilterSetup
---@field side 'low'|'high'
---@field to_value fun(hz: number): number cutoff macro value 0..1 for a cutoff in Hz
---@field open_value number macro value of the open filter (1 for low-pass, 0 for high-pass)

---@param target renoise.Instrument
---@param side 'low'|'high'
---@param resonance number share of the resonance range (import option, 0..0.3)
---@return AhxFilterSetup
local function write(target, side, resonance)
  local to_value, mapping, filter_type
  for index, modulation_set in ipairs(target.sample_modulation_sets) do
    filter_type = side == 'low' and pick_filter_type(modulation_set.available_filter_types, LOW_PASS_TYPES, 'LP')
      or pick_filter_type(modulation_set.available_filter_types, HIGH_PASS_TYPES, 'HP')
    if not filter_type then
      error('no ' .. side .. '-pass filter type available')
    end
    modulation_set.filter_type = filter_type
    -- Resonance from the import options (shown 0..1 like the cutoff); the Renoise default was too colored by ear.
    local resonance_input = modulation_set.resonance_input
    local resonance_range = resonance_input.value_max - resonance_input.value_min
    resonance_input.value = resonance_input.value_min + resonance_range * resonance
    if index == 1 then
      -- The macro maps 0..1 linearly onto the cutoff input, so the macro value is the input's share of its range.
      to_value, mapping = cutoff_mapping(modulation_set.cutoff_input)
    end
  end
  Util.log('%s: %s-pass "%s", cutoff %s', target.name, side, filter_type, mapping)
  return { side = side, to_value = to_value, open_value = side == 'low' and 1 or 0 }
end

---Sets up the Renoise filter of an instrument; failures are reported instead of stopping the import (the instrument
---stays unfiltered).
---@param target renoise.Instrument
---@param side 'low'|'high'
---@param resonance number share of the resonance range (import option, 0..0.3)
---@param report fun(name: string)
---@return AhxFilterSetup|nil
function FilterWriter.write(target, side, resonance, report)
  local ok, result = pcall(write, target, side, resonance)
  if not ok then
    Util.log('%s: Renoise filter not written: %s', target.name, tostring(result))
    report('Renoise filter (setup failed, see log; instrument unfiltered)')
    return nil
  end
  return result
end

return FilterWriter
