-- Import options dialog, shown before every import. It starts with the saved options; Save stores the current
-- choice (the Save button shows a check mark while the choice equals the saved options). Return imports, Esc cancels.

local Preferences = require('importer.preferences')
local Widgets = require('importer.ui.widgets')

local OptionsDialog = {}

local CONTENT_WIDTH = 320
local POPUP_WIDTH = 160

-- Base sample rate of the samples, see `SampleWriter`.
local BASE_SAMPLE_RATE = 8363

---@param values integer[]
---@param wanted integer
---@return integer index of `wanted` in `values` (1 when missing)
local function index_of(values, wanted)
  for index, value in ipairs(values) do
    if value == wanted then
      return index
    end
  end
  return 1
end

---@param song AhxSong
---@param file_name string
---@param on_import fun(options: AhxImportOptions)
---@param on_cancel fun()|nil
function OptionsDialog.show(song, file_name, on_import, on_cancel)
  local vb = renoise.ViewBuilder()
  local options = Preferences.load()
  local close

  local bit_depth_labels = {}
  for index, value in ipairs(Preferences.BIT_DEPTHS) do
    bit_depth_labels[index] = ('%d bit'):format(value)
  end
  local sample_rate_labels = {}
  for index, value in ipairs(Preferences.SAMPLE_RATE_FACTORS) do
    sample_rate_labels[index] = ('%d Hz (%d×)'):format(BASE_SAMPLE_RATE * value, value)
  end

  local function update_saved_mark()
    local saved = Preferences.is_saved(options)
    -- Heavy check mark in bold: the light one (✓) looked too thin.
    vb.views.save_button.text = saved and '✔ Save' or 'Save'
    vb.views.save_button.font = saved and 'bold' or 'normal'
    -- Nothing to save while the choice equals the saved options.
    vb.views.save_button.active = not saved
  end

  local function cancel()
    close()
    if on_cancel then
      on_cancel()
    end
  end

  local function import()
    close()
    on_import({
      interpolation = options.interpolation,
      bit_depth = options.bit_depth,
      sample_rate_factor = options.sample_rate_factor,
    })
  end

  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    Widgets.header(
      vb,
      'Import AHX Song',
      ('%s – %s (THX%d)'):format(Widgets.basename(file_name), song.name, song.revision)
    ),
    Widgets.section(vb, 'Samples', {
      Widgets.labeled(
        vb,
        'Interpolation',
        vb:popup {
          width = POPUP_WIDTH,
          items = Preferences.INTERPOLATIONS,
          value = options.interpolation,
          notifier = function(value)
            options.interpolation = value
            update_saved_mark()
          end,
        }
      ),
      Widgets.labeled(
        vb,
        'Resolution',
        vb:popup {
          width = POPUP_WIDTH,
          items = bit_depth_labels,
          value = index_of(Preferences.BIT_DEPTHS, options.bit_depth),
          notifier = function(value)
            options.bit_depth = Preferences.BIT_DEPTHS[value]
            update_saved_mark()
          end,
        }
      ),
      Widgets.labeled(
        vb,
        'Sample rate',
        vb:popup {
          width = POPUP_WIDTH,
          items = sample_rate_labels,
          value = index_of(Preferences.SAMPLE_RATE_FACTORS, options.sample_rate_factor),
          notifier = function(value)
            options.sample_rate_factor = Preferences.SAMPLE_RATE_FACTORS[value]
            update_saved_mark()
          end,
        }
      ),
      vb:text {
        text = 'None keeps the hard, aliased sound of the Amiga.',
        style = 'disabled',
      },
    }, CONTENT_WIDTH),
    Widgets.footer(vb, {
      Widgets.button(vb, {
        id = 'save_button',
        text = 'Save',
        tooltip = 'Save these options as default (a check mark shows they are saved)',
        notifier = function()
          Preferences.save(options)
          update_saved_mark()
        end,
      }),
      Widgets.button(vb, { text = 'Cancel', tooltip = 'Esc', notifier = cancel }),
      Widgets.button(vb, { text = 'Import', kind = 'primary', tooltip = 'Return', notifier = import }),
    }),
  }

  update_saved_mark()
  close = Widgets.show_dialog('Import Options', content, { ['return'] = import, esc = cancel }, on_cancel)
end

return OptionsDialog
