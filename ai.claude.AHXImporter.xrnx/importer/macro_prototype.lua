-- @build:skip-start
-- Development prototype: checks the macro automation route before the importer uses it.
--   * A new instrument is loaded from a generated template (`XrniWriter`) with macro 1 "Volume" mapped to the volume
--     input of its modulation sets, and gets one looped square wave sample that uses set 1.
--   * The console lists the macro mappings and the volume input at macro values 0..1 (scaling of the input).
--   * Track 1 gets an *Instr. Macros device linked to the instrument; the selected pattern gets a C-4 on line 1 of
--     track 1 and a volume ramp (0 -> 1 over the pattern, lines mode) on the device's macro 1.

local Util = require('importer.util')
local XrniWriter = require('importer.xrni_writer')

local MacroPrototype = {}

local SAMPLE_RATE = 8363
local CYCLE = 32
local FRAMES = 256

---@param rns renoise.Song
---@param instrument renoise.Instrument
local function write_sample(rns, instrument)
  local sample = #instrument.samples > 0 and instrument.samples[1] or instrument:insert_sample_at(1)
  local buffer = sample.sample_buffer
  if not buffer:create_sample_data(SAMPLE_RATE, 16, 1, FRAMES) then
    error('out of memory')
  end
  buffer:prepare_sample_data_changes(false)
  for frame = 1, FRAMES do
    buffer:set_sample_data(1, frame, ((frame - 1) % CYCLE) < CYCLE / 2 and 0.5 or -0.5)
  end
  buffer:finalize_sample_data_changes()
  sample.name = 'Square'
  sample.loop_mode = renoise.Sample.LOOP_MODE_FORWARD
  sample.loop_start = 1
  sample.loop_end = FRAMES
  sample.sample_mapping.base_note = 48
  sample.modulation_set_index = 1
  rns.selected_sample_index = 1
end

---@param instrument renoise.Instrument
local function log_mappings(instrument)
  Util.log('Prototype: %d modulation sets', #instrument.sample_modulation_sets)
  for number, instrument_macro in ipairs(instrument.macros) do
    for _, mapping in ipairs(instrument_macro.mappings) do
      Util.log(
        'Prototype: macro %d "%s" -> %s (min %.2f, max %.2f, scaling %d)',
        number,
        instrument_macro.name,
        mapping.parameter.name,
        mapping.parameter_min,
        mapping.parameter_max,
        mapping.parameter_scaling
      )
    end
  end

  local volume = instrument.sample_modulation_sets[1].volume_input
  for _, value in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
    instrument.macros[1].value = value
    Util.log('Prototype: macro 1 = %.2f -> volume input %.4f (%s)', value, volume.value, volume.value_string)
  end
  Util.log('Prototype: volume input range %s .. %s', tostring(volume.value_min), tostring(volume.value_max))
  instrument.macros[1].value = 1
end

---@param track renoise.Track
---@param index integer 1-based instrument index
---@return renoise.AudioDevice
local function insert_macro_device(track, index)
  local path = nil
  for _, candidate in ipairs(track.available_devices) do
    if candidate:find('Instr. Macros', 1, true) then
      path = candidate
      break
    end
  end
  if not path then
    error('no *Instr. Macros device available')
  end
  local device = track:insert_device_at(path, #track.devices + 1)
  local data, count = device.active_preset_data:gsub(
    '<LinkedInstrument>%-?%d+</LinkedInstrument>',
    ('<LinkedInstrument>%d</LinkedInstrument>'):format(index - 1)
  )
  Util.log('Prototype: LinkedInstrument replaced %d time(s)', count)
  device.active_preset_data = data
  Util.log('Prototype: device "%s" -> %s', device.display_name, Util.describe_parameters(device))
  return device
end

---@param rns renoise.Song
---@param device renoise.AudioDevice
---@param index integer 1-based instrument index
local function write_pattern(rns, device, index)
  local parameter = device.parameters[1]
  for _, candidate in ipairs(device.parameters) do
    if candidate.name:lower():find('volume', 1, true) then
      parameter = candidate
      break
    end
  end
  Util.log('Prototype: automating device parameter "%s"', parameter.name)

  local pattern = rns.patterns[rns.selected_pattern_index]
  local pattern_track = pattern:track(1)
  local column = pattern_track:line(1).note_columns[1]
  column.note_value = 48
  column.instrument_value = index - 1

  local automation = pattern_track:find_automation(parameter) or pattern_track:create_automation(parameter)
  automation:clear()
  automation.playmode = renoise.PatternTrackAutomation.PLAYMODE_LINES
  local lines = pattern.number_of_lines
  for line = 1, lines do
    automation:add_point_at(line, (line - 1) / math.max(1, lines - 1))
  end
end

function MacroPrototype.run()
  local rns = renoise.song()
  local index = #rns.instruments + 1
  rns:insert_instrument_at(index)
  local instrument = XrniWriter.load(index, {
    set_count = 2,
    macros = { [1] = { name = 'Volume', parameter = XrniWriter.VOLUME, value = 1 } },
  })
  instrument.name = 'Macro prototype'
  write_sample(rns, instrument)
  log_mappings(instrument)
  local device = insert_macro_device(rns.tracks[1], index)
  write_pattern(rns, device, index)
  renoise.app():show_status('AHX macro prototype written (see scripting console)')
end

return MacroPrototype
-- @build:skip-end
