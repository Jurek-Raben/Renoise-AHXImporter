-- Runs long operations as a coroutine, sliced over Renoise idle calls, with a progress dialog and cancel button.
-- Long running functions call `ProcessSlicer.step(status)` regularly; it only yields when the current time slice is
-- used up, so it is cheap to call often. Outside of a sliced process `step` does nothing.

local Util = require('importer.util')

local M = {}

-- Time budget per idle call in milliseconds.
local SLICE_MS = 40

-- Safety net: yield at least after this many steps, even if the time measurement is off.
local MAX_STEPS_PER_SLICE = 50

-- Number of idle intervals measured to detect the unit of os.clock().
local CLOCK_SAMPLES = 3

-- The Renoise docs say os.clock() is "still expressed in milliseconds", while standard Lua returns seconds.
-- The unit is detected once from idle call intervals (always well below one second): milliseconds per os.clock unit.
local clock_ms_per_unit = nil

-- Error value used to unwind the coroutine when the user cancels.
M.CANCELLED = setmetatable({}, {
  __tostring = function()
    return 'cancelled'
  end,
})

local current = nil

---@return boolean
function M.is_running()
  return current ~= nil
end

---Requests the running process to stop at its next step, also when it is not cancellable by the user (e.g. because
---the song it works on was replaced).
function M.cancel()
  if current then
    current.cancelled = true
  end
end

---Yields to Renoise when the time slice is used up. Raises M.CANCELLED when the user cancelled.
---@param status string|nil progress text shown in the dialog
---@param force boolean|nil always yield, e.g. after a single long API call such as loading an instrument
function M.step(status, force)
  local task = current
  if task == nil or coroutine.running() ~= task.coroutine then
    return
  end
  if status then
    task.status = status
  end
  task.steps = task.steps + 1
  local elapsed_ms = (os.clock() - task.slice_start) * clock_ms_per_unit
  if force or elapsed_ms >= SLICE_MS or task.steps >= MAX_STEPS_PER_SLICE then
    coroutine.yield()
  end
  if task.cancelled then
    error(M.CANCELLED, 0)
  end
end

---@param task table
local function show_progress(task)
  local vb = renoise.ViewBuilder()
  task.status_view = vb:text { text = task.status, width = 360 }
  local content = vb:column {
    margin = 8,
    spacing = 6,
    task.status_view,
    vb:horizontal_aligner {
      mode = 'right',
      visible = task.cancellable,
      vb:button {
        text = 'Cancel',
        width = 80,
        notifier = function()
          task.cancelled = true
        end,
      },
    },
  }
  task.dialog = renoise.app():show_custom_dialog(Util.TOOL_NAME .. ' - ' .. task.title, content)
end

---@param task table
local function close_progress(task)
  if task.dialog and task.dialog.visible then
    task.dialog:close()
  end
  task.dialog = nil
end

---Runs `fn(...)` sliced. Calls `on_done(true, result)` on success, `on_done(false, M.CANCELLED)` when cancelled
---or `on_done(false, error_message)` on errors (with a traceback in the console).
---@param title string
---@param cancellable boolean false for operations that must not stop halfway (e.g. modifying the target song)
---@param fn function
---@param on_done fun(ok: boolean, result: any)
function M.run(title, cancellable, fn, on_done, ...)
  if current then
    error('Another sliced process is still running')
  end
  local args = { ... }
  local task = {
    title = title,
    status = title .. '...',
    cancellable = cancellable,
    cancelled = false,
    slice_start = 0,
    steps = 0,
    clock_samples = {},
  }

  task.coroutine = coroutine.create(function()
    return xpcall(function()
      return fn(unpack(args))
    end, function(err)
      if err ~= M.CANCELLED then
        Util.log('ERROR: %s\n%s', tostring(err), debug.traceback())
      end
      return err
    end)
  end)

  local idle = renoise.tool().app_idle_observable

  local function finish(ok, result)
    idle:remove_notifier(task.on_idle)
    close_progress(task)
    current = nil
    on_done(ok, result)
  end

  task.on_idle = function()
    if task.dialog and not task.dialog.visible then
      -- The progress dialog was closed with the window button.
      task.dialog = nil
      task.status_view = nil
      task.cancelled = task.cancellable
    end
    if clock_ms_per_unit == nil then
      -- Measure a few idle intervals before starting the work; the smallest one is used.
      local now = os.clock()
      if task.last_idle then
        task.clock_samples[#task.clock_samples + 1] = now - task.last_idle
      end
      task.last_idle = now
      if #task.clock_samples < CLOCK_SAMPLES then
        return
      end
      local interval = math.min(unpack(task.clock_samples))
      -- An idle interval of >= 1 unit can only be milliseconds. Misdetecting seconds as milliseconds is avoided
      -- by using the minimum interval; the opposite error would only yield more often (safe).
      clock_ms_per_unit = interval >= 1 and 1 or 1000
      Util.log('os.clock() unit detected: %s (idle interval %s)', clock_ms_per_unit == 1 and 'ms' or 's', interval)
    end
    task.slice_start = os.clock()
    task.steps = 0
    local resumed, ok, result = coroutine.resume(task.coroutine)
    if not resumed then
      -- Errors are caught by xpcall inside the coroutine, so this only happens on internal failures.
      finish(false, ok)
    elseif coroutine.status(task.coroutine) == 'dead' then
      finish(ok, result)
    elseif task.status_view then
      task.status_view.text = task.status
    end
  end

  current = task
  show_progress(task)
  idle:add_notifier(task.on_idle)
end

return M
