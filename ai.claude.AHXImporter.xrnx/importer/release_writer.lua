-- Adds a release to instruments whose AHX hard cut fades out instead of cutting (`HardCutRelease`): a volume AHDSR
-- that stays at full level until the note-off the pattern writes before the next trigger, then releases over the
-- hard cut frames.

local Util = require('importer.util')

local ReleaseWriter = {}

---@param modulation_set renoise.SampleModulationSet
---@return string|nil
local function ahdsr_device_path(modulation_set)
  for _, path in ipairs(modulation_set.available_devices) do
    if path:find('AHDSR', 1, true) then
      return path
    end
  end
  return nil
end

---@param ahdsr renoise.SampleModulationDevice
---@param release_ms number
local function configure(ahdsr, release_ms)
  for _, name in ipairs({ 'Attack', 'Hold', 'Decay' }) do
    local value = Util.parameter(ahdsr, name)
    value.value = value.value_min
  end
  local sustain = Util.parameter(ahdsr, 'Sustain')
  sustain.value = sustain.value_max
  -- The release accepts a value string in ms, like the LFO delay (verified).
  Util.parameter(ahdsr, 'Release').value_string = ('%d ms'):format(math.floor(release_ms + 0.5))
end

---@param target renoise.Instrument
---@param release_ms number
local function write(target, release_ms)
  if #target.sample_modulation_sets == 0 then
    target:insert_sample_modulation_set_at(1)
  end
  local modulation_set = target.sample_modulation_sets[1]
  local path = ahdsr_device_path(modulation_set)
  if not path then
    error('no AHDSR modulation device available')
  end

  local ahdsr = modulation_set:insert_device_at(path, renoise.SampleModulationDevice.TARGET_VOLUME, 1)
  local ok, message = pcall(configure, ahdsr, release_ms)
  if not ok then
    -- Never leave an AHDSR with default settings behind.
    Util.log('%s: AHDSR parameters: %s', target.name, Util.describe_parameters(ahdsr))
    modulation_set:delete_device_at(1)
    error(message, 0)
  end

  for _, sample in ipairs(target.samples) do
    sample.modulation_set_index = 1
  end
  Util.log(
    '%s: hard cut release %d ms -> %s',
    target.name,
    math.floor(release_ms + 0.5),
    Util.describe_parameters(ahdsr)
  )
end

---Adds the release; failures are reported instead of stopping the import.
---@param target renoise.Instrument
---@param instrument AhxInstrument
---@param frames_per_second number
---@param report fun(name: string)
function ReleaseWriter.write(target, instrument, frames_per_second, report)
  if instrument.hard_cut_release == 0 or instrument.hard_cut_release_frames == 0 then
    return
  end
  local ok, message = pcall(write, target, instrument.hard_cut_release_frames * 1000 / frames_per_second)
  if not ok then
    Util.log('%s: hard cut release not written: %s', target.name, tostring(message))
    report('hard cut release (AHDSR setup failed, see above)')
  end
end

return ReleaseWriter
