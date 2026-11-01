-- Small shared helpers of the importer.

local Util = {}

Util.TOOL_NAME = 'AHX Importer'

---Prints a formatted line to the Renoise scripting console.
---@param format string
function Util.log(format, ...)
  print(('[%s] %s'):format(Util.TOOL_NAME, format:format(...)))
end

---Finds a device parameter by name (case-insensitive prefix). Typed device fields are not available at runtime for
---all devices (observed with the LFO in Renoise 3.5.4), so parameters are looked up in `device.parameters`.
---@param device renoise.AudioDevice|renoise.SampleModulationDevice
---@param name string
---@return renoise.DeviceParameter
function Util.parameter(device, name)
  local wanted = name:lower()
  for _, candidate in ipairs(device.parameters) do
    if candidate.name:lower():sub(1, #wanted) == wanted then
      return candidate
    end
  end
  error(('device parameter "%s" not found'):format(name))
end

---All parameters of a device with their values, for the console.
---@param device renoise.AudioDevice|renoise.SampleModulationDevice
---@return string
function Util.describe_parameters(device)
  local parts = {}
  for _, candidate in ipairs(device.parameters) do
    parts[#parts + 1] = ('%s = %s'):format(candidate.name, candidate.value_string)
  end
  return table.concat(parts, ', ')
end

---Calls `on_closed` once a dialog was closed with its window button. Stops watching when `is_finished` returns true
---(the dialog was closed by its own buttons).
---@param get_dialog fun(): renoise.Dialog|nil
---@param is_finished fun(): boolean
---@param on_closed fun()
function Util.watch_dialog(get_dialog, is_finished, on_closed)
  local idle = renoise.tool().app_idle_observable
  local function check()
    local dialog = get_dialog()
    if is_finished() then
      idle:remove_notifier(check)
    elseif dialog and not dialog.visible then
      idle:remove_notifier(check)
      on_closed()
    end
  end
  idle:add_notifier(check)
end

return Util
