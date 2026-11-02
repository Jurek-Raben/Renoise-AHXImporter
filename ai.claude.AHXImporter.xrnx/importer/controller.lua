-- Import workflow: pick or receive a file, parse it, ask for the import options, create a new song and build it
-- sliced with a progress dialog.

local NoteUsage = require('ahx.note_usage')
local Parser = require('ahx.parser')
local PatternConverter = require('ahx.pattern_converter')
local Resolution = require('ahx.resolution')
local Sequence = require('ahx.sequence')
local Timing = require('ahx.timing')
local InstrumentWriter = require('importer.instrument_writer')
local PatternWriter = require('importer.pattern_writer')
local ProcessSlicer = require('importer.process_slicer')
local SongCreator = require('importer.song_creator')
local SongSetup = require('importer.song_setup')
local OptionsDialog = require('importer.ui.options_dialog')
local Widgets = require('importer.ui.widgets')
local Util = require('importer.util')

local Controller = {}

---@param song AhxSong
---@param file_name string
---@return string
local function song_name(song, file_name)
  local name = song.name:match('^%s*(.-)%s*$')
  if name == '' then
    name = Widgets.basename(file_name):gsub('%.[^.]*$', '')
  end
  return name
end

---Builds the whole song. Runs inside the process slicer.
---@param song AhxSong
---@param file_name string
---@param options AhxImportOptions
---@return table summary
local function build_song(song, file_name, options)
  local rns = renoise.song()
  rns:describe_undo('Import AHX Song')

  ProcessSlicer.step('Preparing song', true)
  SongSetup.prepare()
  rns.name = song_name(song, file_name)
  rns.comments = { ('Imported from %s (THX%d) by %s'):format(file_name, song.revision, Util.TOOL_NAME) }

  local unsupported = {}
  local function report(name)
    unsupported[name] = (unsupported[name] or 0) + 1
  end

  local plan = Timing.plan(song)
  if not plan.exact then
    report('speed combination (rows approximated)')
  end
  -- Pre-pass over the play order: the triggered notes, square offsets and following slides decide the phrases.
  local triggers = PatternConverter.scan_triggers(song, plan, Sequence.build(song, 0))
  local usage, trigger_keys = NoteUsage.from_triggers(song, triggers)
  local variant_phrases = InstrumentWriter.write_all(song, plan, report, options, usage)
  local lines_per_row = options.lines_per_row
  if lines_per_row == 0 then
    local highest_x
    lines_per_row, highest_x = Resolution.auto(song, 0)
    Util.log('Pattern resolution auto: %d× (highest vibrato speed at 1×: %.1f)', lines_per_row, highest_x)
  end
  -- A Renoise pattern has at most 512 lines.
  while lines_per_row > 1 and song.track_length * lines_per_row > 512 do
    lines_per_row = lines_per_row / 2
    report('pattern resolution reduced (more than 512 lines per pattern)')
  end
  local summary = PatternWriter.write_song(song, 0, plan, report, variant_phrases, lines_per_row, trigger_keys)
  summary.unsupported = unsupported

  rns.selected_instrument_index = 1
  rns.selected_sequence_index = 1
  -- Set again at the end: the song name is the AHX song name (the file name when it is empty).
  rns.name = song_name(song, file_name)
  return summary
end

---@param song AhxSong
---@param summary table
local function report(song, summary)
  local lines = {}
  for name, count in pairs(summary.unsupported) do
    lines[#lines + 1] = ('  %s: %dx'):format(name, count)
  end
  table.sort(lines)

  Util.log(
    '"%s": %d instruments, %d patterns, sequence length %d, loop to %s',
    song.name,
    song.instrument_count,
    summary.patterns,
    summary.sequence_length,
    tostring(summary.loop_to)
  )
  if summary.truncated then
    Util.log('Sequence truncated at the Renoise limit')
  end
  if #lines > 0 then
    Util.log('Not converted yet:\n%s', table.concat(lines, '\n'))
  end

  renoise.app():show_status(
    ('AHX import: "%s" – %d instruments, %d patterns%s'):format(
      song.name,
      song.instrument_count,
      summary.patterns,
      #lines > 0 and ' (some commands not converted yet, see scripting console)' or ''
    )
  )
end

---Imports an AHX file into a new song.
---@param file_name string
---@return boolean success the file is a valid AHX file and the import was started
function Controller.import_file(file_name)
  if ProcessSlicer.is_running() then
    renoise.app():show_warning('An AHX import is still running.')
    return false
  end

  local song, parse_error = Parser.parse_file(file_name)
  if not song then
    renoise.app():show_error('AHX import failed:\n' .. tostring(parse_error))
    return false
  end

  OptionsDialog.show(song, file_name, function(options)
    Controller.build(song, file_name, options)
  end)
  return true
end

---Creates the new song and builds it.
---@param song AhxSong
---@param file_name string
---@param options AhxImportOptions
function Controller.build(song, file_name, options)
  SongCreator.create(function()
    -- Song objects die when the document is replaced during the sliced build; stop instead of failing halfway.
    local song_replaced = false
    local new_document_observable = renoise.tool().app_new_document_observable
    local function on_new_document()
      song_replaced = true
      ProcessSlicer.cancel()
    end
    new_document_observable:add_notifier(on_new_document)

    ProcessSlicer.run(('Importing "%s"'):format(Widgets.basename(file_name)), true, build_song, function(ok, result)
      if new_document_observable:has_notifier(on_new_document) then
        new_document_observable:remove_notifier(on_new_document)
      end
      if ok then
        report(song, result)
      elseif song_replaced then
        renoise.app():show_error('AHX import stopped: the song was replaced while importing. Please import again.')
      elseif result == ProcessSlicer.CANCELLED then
        renoise.app():show_status('AHX import cancelled')
      else
        renoise.app():show_error('AHX import failed:\n' .. tostring(result))
      end
    end, song, file_name, options)
  end)
end

---Asks for a file and imports it.
function Controller.start()
  local file_name = renoise.app():prompt_for_filename_to_read({ 'ahx', 'thx' }, 'Import AHX Song')
  if file_name ~= '' then
    Controller.import_file(file_name)
  end
end

return Controller
