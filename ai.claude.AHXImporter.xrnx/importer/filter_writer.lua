-- Writes the Renoise-filter path (see `FilterPath`): a modulation set per sample with a low- or high-pass filter and a
-- cutoff envelope that holds one point per AHX frame.

local Util = require('importer.util')

local FilterWriter = {}

local LOW_PASS_TYPES = { 'LP 2 Pole', 'LP Clean', 'LP -12 dB' }
local HIGH_PASS_TYPES = { 'HP 2 Pole', 'HP Clean', 'HP -12 dB' }

-- ASSUMPTION: with tempo sync off, envelope times (and `length`) are milliseconds, max 1000.
local MAX_ENVELOPE_MS = 1000

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

---Maps Hz to the cutoff as 0..1 of the parameter range (envelope points must be 0..1), by probing the parameter's
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

---@param modulation_set renoise.SampleModulationSet
---@return string|nil
local function envelope_device_path(modulation_set)
  for _, path in ipairs(modulation_set.available_devices) do
    if path:find('Envelope', 1, true) then
      return path
    end
  end
  return nil
end

---@param target renoise.Instrument
---@param sample renoise.Sample
---@param side 'low'|'high'
---@param envelope AhxCutoffEnvelope
---@param frames_per_second number
---@param resonance number share of the resonance range (import option, 0..0.3)
---@param report fun(name: string)
---@param verbose boolean log the details (once per instrument)
local function write(target, sample, side, envelope, frames_per_second, resonance, report, verbose)
  -- A set of its own, starting as a copy of set 1 (which may hold the hard cut release, see `ReleaseWriter`).
  local index = #target.sample_modulation_sets + 1
  target:insert_sample_modulation_set_at(index)
  local modulation_set = target.sample_modulation_sets[index]
  if index > 1 and sample.modulation_set_index == 1 then
    modulation_set:copy_from(target.sample_modulation_sets[1])
  end
  modulation_set.name = sample.name
  sample.modulation_set_index = index

  local filter_type = side == 'low' and pick_filter_type(modulation_set.available_filter_types, LOW_PASS_TYPES, 'LP')
    or pick_filter_type(modulation_set.available_filter_types, HIGH_PASS_TYPES, 'HP')
  if not filter_type then
    error('no ' .. side .. '-pass filter type available')
  end
  modulation_set.filter_type = filter_type
  -- Resonance from the import options (shown 0..1 like the cutoff); the Renoise default was too colored by ear.
  local resonance_input = modulation_set.resonance_input
  local resonance_range = resonance_input.value_max - resonance_input.value_min
  resonance_input.value = resonance_input.value_min + resonance_range * resonance

  local cutoff = modulation_set.cutoff_input
  local to_value, mapping = cutoff_mapping(cutoff)
  -- The envelope multiplies the full cutoff, so its value is the normalized cutoff itself.
  -- ASSUMPTION: a unipolar envelope with operator "multiply" scales the normalized cutoff input.
  cutoff.value = cutoff.value_max

  local path = envelope_device_path(modulation_set)
  if not path then
    error('no envelope modulation device available')
  end
  local device = modulation_set:insert_device_at(path, renoise.SampleModulationDevice.TARGET_CUTOFF, 1)
  device.operator = renoise.SampleModulationDevice.OPERATOR_MUL
  device.bipolar = false
  if device.tempo_sync_switching_allowed then
    device.tempo_synced = false
  end
  device.play_mode = renoise.SampleEnvelopeModulationDevice.PLAYMODE_POINTS

  local ms_per_frame = 1000 / frames_per_second
  local frame_count = #envelope.cutoffs
  local max_frames = math.floor(MAX_ENVELOPE_MS / ms_per_frame)
  if frame_count > max_frames then
    report('filter envelope longer than 1 s (cut)')
    frame_count = max_frames
  end

  local function time_of(frame)
    return 1 + math.floor((frame - 1) * ms_per_frame + 0.5)
  end
  local open_value = side == 'low' and 1 or 0
  local points = {}
  for frame = 1, frame_count do
    local hz = envelope.cutoffs[frame]
    local value = hz and to_value(hz) or open_value
    points[#points + 1] = { time = time_of(frame), value = value, scaling = 0 }
  end
  device.length = math.max(6, time_of(frame_count + 1) - 1)
  device.points = points

  if envelope.loop_start and envelope.loop_end <= frame_count then
    device.loop_mode = renoise.SampleEnvelopeModulationDevice.LOOP_MODE_FORWARD
    device.loop_start = time_of(envelope.loop_start)
    device.loop_end = math.min(device.length, time_of(envelope.loop_end + 1) - 1)
  else
    device.loop_mode = renoise.SampleEnvelopeModulationDevice.LOOP_MODE_OFF
  end

  if verbose then
    Util.log(
      '%s / %s: %s-pass "%s", cutoff %s, envelope %d frames / length %d, loop %s..%s (%s)',
      target.name,
      sample.name,
      side,
      filter_type,
      mapping,
      frame_count,
      device.length,
      tostring(envelope.loop_start),
      tostring(envelope.loop_end),
      Util.describe_parameters(device)
    )
  end
end

---Adds the filter of one sample; failures are reported instead of stopping the import (the sample stays unfiltered).
---@param target renoise.Instrument
---@param sample renoise.Sample
---@param side 'low'|'high'
---@param envelope AhxCutoffEnvelope
---@param frames_per_second number
---@param resonance number share of the resonance range (import option, 0..0.3)
---@param report fun(name: string)
---@param verbose boolean log the details (once per instrument)
function FilterWriter.write(target, sample, side, envelope, frames_per_second, resonance, report, verbose)
  local ok, message = pcall(write, target, sample, side, envelope, frames_per_second, resonance, report, verbose)
  if not ok then
    if verbose then
      Util.log('%s / %s: Renoise filter not written: %s', target.name, sample.name, tostring(message))
    end
    report('Renoise filter (setup failed, see log; sample unfiltered)')
  end
end

return FilterWriter
