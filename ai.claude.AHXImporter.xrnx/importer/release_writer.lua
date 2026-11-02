-- Adds a volume AHDSR (full level until note-off, then release) to an instrument, for one of two purposes:
--   * Hard cut release (`HardCutRelease`): the note-off the pattern writes before the next trigger releases over the
--     hard cut frames.
--   * PWM crossfade (import option): with new note action "note off", every sample switch of a phrase releases the
--     old sample over a few ms while the new one fades in with the same attack, which smooths the switches.
-- The hard cut release wins: with "note off" its long release let old notes fade underneath and modulated the volume
-- (syphus - better days, bass on AHX 1), so those instruments keep "note cut" without crossfade.

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
---@param attack_ms number
---@param release_ms number
local function configure(ahdsr, attack_ms, release_ms)
  for _, name in ipairs({ 'Hold', 'Decay' }) do
    local value = Util.parameter(ahdsr, name)
    value.value = value.value_min
  end
  local attack = Util.parameter(ahdsr, 'Attack')
  if attack_ms > 0 then
    -- ASSUMPTION: the attack accepts a value string in ms, like the release.
    attack.value_string = ('%d ms'):format(math.floor(attack_ms + 0.5))
  else
    attack.value = attack.value_min
  end
  local sustain = Util.parameter(ahdsr, 'Sustain')
  sustain.value = sustain.value_max
  -- The release accepts a value string in ms, like the LFO delay (verified).
  Util.parameter(ahdsr, 'Release').value_string = ('%d ms'):format(math.floor(release_ms + 0.5))
end

---@param target renoise.Instrument
---@param attack_ms number
---@param release_ms number
---@param purpose string for the console
local function write(target, attack_ms, release_ms, purpose)
  if #target.sample_modulation_sets == 0 then
    target:insert_sample_modulation_set_at(1)
  end
  local modulation_set = target.sample_modulation_sets[1]
  local path = ahdsr_device_path(modulation_set)
  if not path then
    error('no AHDSR modulation device available')
  end

  local ahdsr = modulation_set:insert_device_at(path, renoise.SampleModulationDevice.TARGET_VOLUME, 1)
  local ok, message = pcall(configure, ahdsr, attack_ms, release_ms)
  if not ok then
    -- Never leave an AHDSR with default settings behind.
    Util.log('%s: AHDSR parameters: %s', target.name, Util.describe_parameters(ahdsr))
    modulation_set:delete_device_at(1)
    error(message, 0)
  end

  for _, sample in ipairs(target.samples) do
    sample.modulation_set_index = 1
  end
  Util.log('%s: %s -> %s', target.name, purpose, Util.describe_parameters(ahdsr))
end

---Adds the hard cut release or the PWM crossfade; failures are reported instead of stopping the import. Returns true
---when the crossfade was written.
---@param target renoise.Instrument
---@param instrument AhxInstrument
---@param frames_per_second number
---@param crossfade_ms number PWM crossfade from the import options (0 = off)
---@param report fun(name: string)
---@return boolean crossfaded
function ReleaseWriter.write(target, instrument, frames_per_second, crossfade_ms, report)
  if instrument.hard_cut_release ~= 0 and instrument.hard_cut_release_frames > 0 then
    local release_ms = instrument.hard_cut_release_frames * 1000 / frames_per_second
    local ok, message = pcall(write, target, 0, release_ms, ('hard cut release %d ms'):format(release_ms))
    if not ok then
      Util.log('%s: hard cut release not written: %s', target.name, tostring(message))
      report('hard cut release (AHDSR setup failed, see log)')
    end
    return false
  end

  if crossfade_ms <= 0 then
    return false
  end
  local ok, message = pcall(write, target, crossfade_ms, crossfade_ms, ('PWM crossfade %d ms'):format(crossfade_ms))
  if not ok then
    Util.log('%s: PWM crossfade not written: %s', target.name, tostring(message))
    report('PWM crossfade (AHDSR setup failed, see log)')
    return false
  end
  for _, sample in ipairs(target.samples) do
    sample.new_note_action = renoise.Sample.NEW_NOTE_ACTION_NOTE_OFF
  end
  return true
end

---The note start must not fade in: the samples of the phrases' first lines get a copy of modulation set 1 without
---attack (the release stays, so they still crossfade into the next sample).
---@param target renoise.Instrument
---@param samples renoise.Sample[]
---@param report fun(name: string)
function ReleaseWriter.write_start_set(target, samples, report)
  if #samples == 0 then
    return
  end
  local ok, message = pcall(function()
    local index = #target.sample_modulation_sets + 1
    target:insert_sample_modulation_set_at(index)
    local modulation_set = target.sample_modulation_sets[index]
    modulation_set:copy_from(target.sample_modulation_sets[1])
    modulation_set.name = 'Note start'
    for _, device in ipairs(modulation_set.devices) do
      if device.name:find('AHDSR', 1, true) then
        local attack = Util.parameter(device, 'Attack')
        attack.value = attack.value_min
      end
    end
    for _, sample in ipairs(samples) do
      sample.modulation_set_index = index
    end
  end)
  if not ok then
    Util.log('%s: note start set not written: %s', target.name, tostring(message))
    report('PWM crossfade note start (setup failed, see log; starts fade in)')
  end
end

return ReleaseWriter
