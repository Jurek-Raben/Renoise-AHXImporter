-- Import options dialog, shown before every import. It starts with the saved options; Save stores the current
-- choice (the Save button shows a check mark while the choice equals the saved options). Return imports, Esc cancels.

local Preferences = require('importer.preferences')
local Widgets = require('importer.ui.widgets')

local OptionsDialog = {}

local CONTENT_WIDTH = 320
local POPUP_WIDTH = 160

---@param ms integer
---@return string
local function crossfade_label(ms)
  return ms == 0 and 'off' or ('%d ms'):format(ms)
end

-- Tooltips of the options (English).
local TOOLTIPS = {
  interpolation = 'How Renoise resamples the samples when playing them. None keeps the hard, aliased sound of the '
    .. 'Amiga; Linear, Cubic and Sinc sound smoother.',
  bit_depth = 'Bit depth of the created samples. AHX waveforms are 8 bit; 16 and 32 bit keep the smoothed and '
    .. 'band-limited renderings finer.',
  rendering = 'How the waveforms are rendered into the samples. Original: every value repeated like the Amiga (hard '
    .. 'edges). Smoothed: cubic interpolation between the values (rounder edges). Band-limited: rebuilt from '
    .. 'harmonics without aliasing at the played pitch.',
  roll_off = 'Band-limited only: share of the harmonics that fades out softly. 0 % cuts hard (can ring like a '
    .. 'steep resonant filter), higher values sound softer.',
  sample_rate = 'Sample rate of the created samples (multiple of the Amiga rate of C-4). Higher rates give the '
    .. 'smoothing room; pitch and timing stay the same.',
  crossfade = 'Crossfade of the sample switches inside a phrase (pulse width modulation, filter steps). Smooths the '
    .. 'rough, ring-modulation-like sound of fast switches. 0 = off. The note start is never faded in.',
  resolution = "Pattern lines per AHX row. Renoise's vibrato speed follows the lines, so slow songs need more lines "
    .. 'for fast vibratos. Auto picks the smallest resolution that fits all vibratos.',
  resonance = 'Resonance of the Renoise filter for filter sweeps that are played by the Renoise filter instead of '
    .. 'baked into the samples.',
}

-- Index of the band-limited rendering in Preferences.RENDERINGS.
local BAND_LIMITED = 3

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
  local resolution_labels = {}
  for index, value in ipairs(Preferences.LINES_PER_ROW) do
    if value == 0 then
      resolution_labels[index] = 'Auto (fits the vibrato)'
    else
      resolution_labels[index] = ('%d× (%d line%s per row)'):format(value, value, value == 1 and '' or 's')
    end
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

  -- The roll-off only applies to band-limited rendering. A disabled slider looks the same as an enabled one, so the
  -- slider and its value are replaced by a note.
  local function update_roll_off()
    local band_limited = options.rendering == BAND_LIMITED
    vb.views.roll_off_slider.active = band_limited
    vb.views.roll_off_slider.visible = band_limited
    vb.views.roll_off_text.visible = band_limited
    vb.views.roll_off_note.visible = not band_limited
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
      rendering = options.rendering,
      filter_resonance = options.filter_resonance,
      lines_per_row = options.lines_per_row,
      crossfade_ms = options.crossfade_ms,
      band_limit_roll_off = options.band_limit_roll_off,
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
          tooltip = TOOLTIPS.interpolation,
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
          tooltip = TOOLTIPS.bit_depth,
          value = index_of(Preferences.BIT_DEPTHS, options.bit_depth),
          notifier = function(value)
            options.bit_depth = Preferences.BIT_DEPTHS[value]
            update_saved_mark()
          end,
        }
      ),
      Widgets.labeled(
        vb,
        'Rendering',
        vb:popup {
          width = POPUP_WIDTH,
          items = Preferences.RENDERINGS,
          tooltip = TOOLTIPS.rendering,
          value = options.rendering,
          notifier = function(value)
            options.rendering = value
            update_roll_off()
            update_saved_mark()
          end,
        }
      ),
      Widgets.labeled(
        vb,
        'Roll-off',
        vb:row {
          spacing = 6,
          vb:slider {
            id = 'roll_off_slider',
            tooltip = TOOLTIPS.roll_off,
            width = POPUP_WIDTH - 40,
            min = 0,
            max = 1,
            default = Preferences.DEFAULT_ROLL_OFF,
            value = options.band_limit_roll_off,
            notifier = function(value)
              options.band_limit_roll_off = value
              vb.views.roll_off_text.text = ('%d %%'):format(math.floor(value * 100 + 0.5))
              update_saved_mark()
            end,
          },
          vb:text {
            id = 'roll_off_text',
            text = ('%d %%'):format(math.floor(options.band_limit_roll_off * 100 + 0.5)),
            width = 40,
          },
          vb:text {
            id = 'roll_off_note',
            text = 'only with Band-limited',
            style = 'disabled',
            width = POPUP_WIDTH,
          },
        }
      ),
      Widgets.labeled(
        vb,
        'Sample rate',
        vb:popup {
          width = POPUP_WIDTH,
          items = sample_rate_labels,
          tooltip = TOOLTIPS.sample_rate,
          value = index_of(Preferences.SAMPLE_RATE_FACTORS, options.sample_rate_factor),
          notifier = function(value)
            options.sample_rate_factor = Preferences.SAMPLE_RATE_FACTORS[value]
            update_saved_mark()
          end,
        }
      ),
      Widgets.labeled(
        vb,
        'PWM crossfade',
        vb:row {
          spacing = 6,
          vb:slider {
            width = POPUP_WIDTH - 40,
            min = 0,
            max = Preferences.MAX_CROSSFADE_MS,
            tooltip = TOOLTIPS.crossfade,
            default = Preferences.DEFAULT_CROSSFADE_MS,
            value = options.crossfade_ms,
            notifier = function(value)
              options.crossfade_ms = math.floor(value + 0.5)
              vb.views.crossfade_text.text = crossfade_label(options.crossfade_ms)
              update_saved_mark()
            end,
          },
          vb:text {
            id = 'crossfade_text',
            text = crossfade_label(options.crossfade_ms),
            width = 40,
          },
        }
      ),
    }, CONTENT_WIDTH),
    Widgets.section(vb, 'Patterns', {
      Widgets.labeled(
        vb,
        'Resolution',
        vb:popup {
          width = POPUP_WIDTH,
          items = resolution_labels,
          tooltip = TOOLTIPS.resolution,
          value = index_of(Preferences.LINES_PER_ROW, options.lines_per_row),
          notifier = function(value)
            options.lines_per_row = Preferences.LINES_PER_ROW[value]
            update_saved_mark()
          end,
        }
      ),
      vb:text {
        text = 'Pattern lines per AHX row. Slow songs need more lines for fast vibratos.',
        style = 'disabled',
      },
    }, CONTENT_WIDTH),
    Widgets.section(vb, 'Filter', {
      Widgets.labeled(
        vb,
        'Resonance',
        vb:row {
          spacing = 6,
          vb:slider {
            width = POPUP_WIDTH - 40,
            min = 0,
            max = Preferences.MAX_FILTER_RESONANCE,
            tooltip = TOOLTIPS.resonance,
            default = Preferences.DEFAULT_FILTER_RESONANCE,
            value = options.filter_resonance,
            notifier = function(value)
              options.filter_resonance = value
              vb.views.resonance_text.text = ('%.3f'):format(value)
              update_saved_mark()
            end,
          },
          vb:text { id = 'resonance_text', text = ('%.3f'):format(options.filter_resonance), width = 40 },
        }
      ),
      vb:text {
        text = 'For filter sweeps played by the Renoise filter.',
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
  update_roll_off()
  close = Widgets.show_dialog('Import Options', content, { ['return'] = import, esc = cancel }, on_cancel)
end

return OptionsDialog
