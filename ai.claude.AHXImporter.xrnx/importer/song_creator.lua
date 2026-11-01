-- Creates a new, template-free song and calls back once it is ready. The tool's Lua state survives song changes, song
-- objects don't.
--
-- When called from a file import hook (drag & drop, disk browser), Renoise still handles the dropped file after the
-- hook returns and may replace the document once more. Therefore the new song is only requested on the next idle
-- call, and the callback waits until no further document has arrived for a few idle calls.

local Util = require('importer.util')

local M = {}

-- When the user aborts Renoise's "save changes?" prompt, no new document arrives. The request is dropped after this
-- many idle calls (and at least MIN_WAIT_SECONDS) without a new document.
local MAX_IDLE_CALLS = 20
local MIN_WAIT_SECONDS = 2

-- Idle calls without another new document before the song counts as settled.
local SETTLE_IDLE_CALLS = 5

local pending = nil

local function remove_notifiers()
  local tool = renoise.tool()
  if pending and tool.app_new_document_observable:has_notifier(pending.on_new_document) then
    tool.app_new_document_observable:remove_notifier(pending.on_new_document)
  end
  if pending and tool.app_idle_observable:has_notifier(pending.on_idle) then
    tool.app_idle_observable:remove_notifier(pending.on_idle)
  end
end

---Drops a pending request.
function M.cancel()
  remove_notifiers()
  pending = nil
end

---Creates a new song without template and calls `callback()` once it is available and settled. Nothing is called
---when the user aborts the save prompt.
---@param callback fun()
function M.create(callback)
  M.cancel()
  local request = { requested = false, idle_calls = 0, requested_at = 0, documents = 0, settle_calls = 0 }
  pending = request

  request.on_idle = function()
    if not request.requested then
      request.requested = true
      request.requested_at = os.time()
      renoise.app():new_song_no_template()
      return
    end

    if request.documents > 0 then
      request.settle_calls = request.settle_calls + 1
      if request.settle_calls >= SETTLE_IDLE_CALLS then
        M.cancel()
        callback()
      end
      return
    end

    request.idle_calls = request.idle_calls + 1
    if request.idle_calls >= MAX_IDLE_CALLS and os.time() - request.requested_at >= MIN_WAIT_SECONDS then
      M.cancel()
    end
  end

  request.on_new_document = function()
    if not request.requested then
      -- A document change caused by the dropped file itself, before our new song was requested.
      Util.log('New document before the new song was requested (ignored)')
      return
    end
    request.documents = request.documents + 1
    Util.log('New document %d after requesting the new song', request.documents)
    request.settle_calls = 0
  end

  renoise.tool().app_new_document_observable:add_notifier(request.on_new_document)
  renoise.tool().app_idle_observable:add_notifier(request.on_idle)
end

return M
