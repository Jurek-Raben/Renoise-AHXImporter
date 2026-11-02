-- Writes the macro automation of the pattern converter (volume and cutoff per frame, see
-- `PatternConverter:advance_volume`): one *Instr. Macros device per track and instrument, and lines-mode automation
-- of its macro parameters.
--
-- A freshly inserted *Instr. Macros device links to the selected instrument (its preset has no `LinkedInstrument`
-- until then; verified with the macro prototype), and its parameters are named like the instrument's macros.

local Util = require('importer.util')

local MacroWriter = {}
MacroWriter.__index = MacroWriter

-- Macro names of the instrument template (see `InstrumentWriter`).
local VOLUME_NAME = 'Volume'
local CUTOFF_NAME = 'Cutoff'

---@param filters table<integer, AhxFilterSetup> Renoise filter per Renoise instrument index
---@return table writer
function MacroWriter.new(filters)
  local self = setmetatable({}, MacroWriter)
  self.filters = filters or {}
  -- Device per `track .. ':' .. instrument`; false when it could not be set up.
  self.devices = {}
  return self
end

---@param track renoise.Track
---@return string|nil
local function macro_device_path(track)
  for _, path in ipairs(track.available_devices) do
    if path:find('Instr. Macros', 1, true) then
      return path
    end
  end
  return nil
end

---The *Instr. Macros device for an instrument on a track; created on first use.
---@param track_index integer
---@param instrument integer Renoise instrument index
---@param report fun(name: string)
---@return renoise.AudioDevice|nil
function MacroWriter:device(track_index, instrument, report)
  local key = track_index .. ':' .. instrument
  local cached = self.devices[key]
  if cached ~= nil then
    return cached or nil
  end

  local rns = renoise.song()
  local track = rns.tracks[track_index]
  local ok, result = pcall(function()
    local path = macro_device_path(track)
    if not path then
      error('no *Instr. Macros device available')
    end
    rns.selected_instrument_index = instrument
    local device = track:insert_device_at(path, #track.devices + 1)
    device.display_name = rns.instruments[instrument].name
    local first = device.parameters[1]
    if not first or first.name ~= VOLUME_NAME then
      local parameters = Util.describe_parameters(device)
      track:delete_device_at(#track.devices)
      error('device not linked to the instrument (' .. parameters .. ')')
    end
    return device
  end)
  if not ok then
    Util.log('%s: macro device for instrument %02d not created: %s', track.name, instrument, tostring(result))
    report('macro automation (macro device setup failed, see log)')
    self.devices[key] = false
    return nil
  end
  self.devices[key] = result
  return result
end

---@param device renoise.AudioDevice
---@param name string macro name
---@return renoise.DeviceParameter|nil
local function parameter_named(device, name)
  for _, parameter in ipairs(device.parameters) do
    if parameter.name == name then
      return parameter
    end
  end
  return nil
end

---Writes points of one macro into a pattern track (lines mode: the value ramps between the points).
---@param pattern_track renoise.PatternTrack
---@param track_index integer
---@param points { time: number, instrument: integer, value: any }[]
---@param name string macro name
---@param to_value fun(instrument: integer, value: any): number|nil automation value 0..1 of a point
---@param report fun(name: string)
function MacroWriter:write(pattern_track, track_index, points, name, to_value, report)
  local automations = {}
  for _, point in ipairs(points) do
    local automation = automations[point.instrument]
    if automation == nil then
      automation = false
      local device = self:device(track_index, point.instrument, report)
      local parameter = device and parameter_named(device, name)
      if parameter then
        automation = pattern_track:find_automation(parameter) or pattern_track:create_automation(parameter)
        automation.playmode = renoise.PatternTrackAutomation.PLAYMODE_LINES
      elseif device then
        Util.log('Instrument %02d: no macro "%s" (%s)', point.instrument, name, Util.describe_parameters(device))
        report('macro automation (macro parameter missing, see log)')
      end
      automations[point.instrument] = automation
    end
    local value = automation and to_value(point.instrument, point.value)
    if value then
      automation:add_point_at(point.time, value)
    end
  end
end

---Writes the volume points of one channel.
---@param pattern_track renoise.PatternTrack
---@param track_index integer
---@param points AhxVolumePoint[]
---@param report fun(name: string)
function MacroWriter:write_volumes(pattern_track, track_index, points, report)
  -- ASSUMPTION: the volume macro scales the amplitude linearly (mapping 0..1 linear onto the volume input 0..1).
  self:write(pattern_track, track_index, points, VOLUME_NAME, function(_, value)
    return value
  end, report)
end

---Writes the cutoff points of one channel (Hz mapped onto the instrument's cutoff input, see `FilterWriter`).
---@param pattern_track renoise.PatternTrack
---@param track_index integer
---@param points AhxCutoffPoint[]
---@param report fun(name: string)
function MacroWriter:write_cutoffs(pattern_track, track_index, points, report)
  local filters = self.filters
  self:write(pattern_track, track_index, points, CUTOFF_NAME, function(instrument, hz)
    local filter = filters[instrument]
    if not filter then
      return nil
    end
    return hz and filter.to_value(hz) or filter.open_value
  end, report)
end

return MacroWriter
