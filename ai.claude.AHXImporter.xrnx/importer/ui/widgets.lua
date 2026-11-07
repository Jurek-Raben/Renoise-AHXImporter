-- Shared building blocks for a consistent dialog look (same look as the SongMerger tool).

local Util = require('importer.util')

local Widgets = {}

Widgets.PRIMARY_COLOR = 'selected_button_back'
Widgets.MARGIN = 10
Widgets.SPACING = 8
Widgets.BUTTON_WIDTH = 96
Widgets.BUTTON_HEIGHT = 24

---Theme color with optional alpha, usable in canvas drawing.
---@param name string theme color name, e.g. 'body_font'
---@param alpha integer|nil 0-255
---@return integer[]
function Widgets.theme_color(name, alpha)
  local ok, color = pcall(function()
    return renoise.app().theme.colors[name]
  end)
  if not ok or type(color) ~= 'table' then
    color = { 128, 128, 128 }
  end
  return { color[1], color[2], color[3], alpha or 255 }
end

---@param path string
---@return string
function Widgets.basename(path)
  return path:match('([^/\\]+)$') or path
end

---Big title with an optional muted subtitle.
---@param vb renoise.ViewBuilder
---@param title string
---@param subtitle string|nil
function Widgets.header(vb, title, subtitle)
  local column = vb:column {
    spacing = 2,
    vb:text { text = title, font = 'big', style = 'strong' },
  }
  if subtitle then
    column:add_child(vb:text { text = subtitle, style = 'disabled' })
  end
  return column
end

local SECTION_MARGIN = 6

---Framed section with a bold title.
---@param vb renoise.ViewBuilder
---@param title string|nil
---@param views renoise.Views.View[]
---@param group table[]|nil collects the section for `Widgets.equalize_sections` (needs a title)
function Widgets.section(vb, title, views, group)
  local column = vb:column {
    background = 'group',
    margin = SECTION_MARGIN,
    spacing = 4,
  }
  if title then
    local title_view = vb:text { text = title, font = 'bold' }
    column:add_child(title_view)
    if group then
      group[#group + 1] = { column = column, title_view = title_view }
    end
  end
  for _, view in ipairs(views) do
    column:add_child(view)
  end
  return column
end

---Gives all sections of a group the width of the widest one. A column fits itself to its children, so its own width
---does not last; the title stretched to the full inner width does, also when the visibility of a child changes.
---ASSUMPTION: the width of a column is already up to date before the dialog is shown.
---@param group table[] filled by `Widgets.section`
---@return integer width of the sections
function Widgets.equalize_sections(group)
  local widest = 0
  for _, section in ipairs(group) do
    widest = math.max(widest, section.column.width)
  end
  for _, section in ipairs(group) do
    section.title_view.width = widest - 2 * SECTION_MARGIN
  end
  return widest
end

---Label/value line.
---@param vb renoise.ViewBuilder
---@param label string
---@param view renoise.Views.View
---@param label_width integer|nil
function Widgets.labeled(vb, label, view, label_width)
  return vb:row {
    vb:text { text = label, width = label_width or 120, style = 'disabled' },
    view,
  }
end

---Dialog button. `kind` is 'primary' or nil.
---@param vb renoise.ViewBuilder
---@param spec { id: string|nil, text: string, kind: string|nil, width: integer|nil, notifier: fun(), tooltip: string? }
function Widgets.button(vb, spec)
  return vb:button {
    id = spec.id,
    text = spec.text,
    width = spec.width or Widgets.BUTTON_WIDTH,
    height = Widgets.BUTTON_HEIGHT,
    color = spec.kind == 'primary' and Widgets.PRIMARY_COLOR or nil,
    font = spec.kind and 'bold' or 'normal',
    tooltip = spec.tooltip,
    notifier = spec.notifier,
  }
end

---Right aligned button bar.
---@param vb renoise.ViewBuilder
---@param views renoise.Views.View[]
function Widgets.footer(vb, views)
  local aligner = vb:horizontal_aligner {
    mode = 'right',
    spacing = 6,
    width = '100%',
  }
  for _, view in ipairs(views) do
    aligner:add_child(view)
  end
  return aligner
end

---Key handler mapping key names (e.g. 'esc', 'return') to actions. Other keys are passed on to Renoise.
---@param actions table<string, fun()>
---@return fun(dialog: renoise.Dialog, key: KeyEvent): KeyEvent|nil
function Widgets.key_handler(actions)
  return function(_, key)
    local action = actions[key.name]
    if action then
      action()
      return nil
    end
    return key
  end
end

---Shows a custom dialog that reports a close via the window button as `on_closed`.
---Returns a `close` function for the dialog's own buttons (which suppresses `on_closed`).
---@param title string
---@param content renoise.Views.View
---@param keys table<string, fun()>|nil
---@param on_closed fun()|nil
---@return fun() close
function Widgets.show_dialog(title, content, keys, on_closed)
  local dialog = nil
  local finished = false
  local function close()
    finished = true
    if dialog and dialog.visible then
      dialog:close()
    end
  end
  dialog = renoise.app():show_custom_dialog(Util.TOOL_NAME .. ' - ' .. title, content, Widgets.key_handler(keys or {}))
  if on_closed then
    Util.watch_dialog(function()
      return dialog
    end, function()
      return finished
    end, function()
      finished = true
      on_closed()
    end)
  end
  return close
end

return Widgets
