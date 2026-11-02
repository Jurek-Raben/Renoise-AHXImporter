-- Writes converted AHX pattern data into Renoise patterns and builds the pattern sequence.

local PatternConverter = require('ahx.pattern_converter')
local Sequence = require('ahx.sequence')
local Timing = require('ahx.timing')
local ProcessSlicer = require('importer.process_slicer')
local SongSetup = require('importer.song_setup')

local PatternWriter = {}

---@param pattern_track renoise.PatternTrack
---@param cells table<integer, AhxCell>
local function write_track(pattern_track, cells)
  for line_index, cell in pairs(cells) do
    local line = pattern_track:line(line_index)
    local column = line.note_columns[1]
    if cell.note then
      column.note_value = cell.note
    elseif cell.note_off then
      column.note_value = 120
    end
    if cell.instrument then
      column.instrument_value = cell.instrument
    end
    if cell.volume then
      column.volume_value = cell.volume
    end
    if cell.delay then
      column.delay_value = cell.delay
    end
    for index, effect in ipairs(cell.effects) do
      local effect_column = line.effect_columns[index]
      effect_column.number_string = effect.number
      effect_column.amount_value = effect.amount
    end
  end
end

---@param segment AhxSegment
---@return string
local function pattern_name(segment)
  if segment.first_row == 0 then
    return ('Pos %03d'):format(segment.position)
  end
  return ('Pos %03d @%02d'):format(segment.position, segment.first_row)
end

---Builds patterns and sequence of a subsong in the current song (prepared by SongSetup).
---@param song AhxSong
---@param subsong integer
---@param plan AhxTimingPlan
---@param report fun(name: string) collects commands that are not converted (yet)
---@param variant_phrases table<integer, table<string, integer>> variant phrase index by instrument and variant key
---@param lines_per_row integer pattern lines per AHX row (pattern resolution option)
---@param trigger_keys table<string, string> variant key by trigger id (`NoteUsage.from_triggers`)
---@return table summary { patterns, sequence_length, loop_to, truncated }
function PatternWriter.write_song(song, subsong, plan, report, variant_phrases, lines_per_row, trigger_keys)
  local rns = renoise.song()
  local sequencer = rns.sequencer
  local sequence = Sequence.build(song, subsong)
  local converter = PatternConverter.new(song, plan, report, variant_phrases, lines_per_row, trigger_keys)

  local lpb, tpl = Timing.for_speed(plan, Timing.INITIAL_SPEED, lines_per_row)
  rns.transport.bpm = plan.bpm
  rns.transport.lpb = lpb
  rns.transport.tpl = tpl

  local pattern_by_key = {}
  local pattern_count = 0
  local max_effect_columns = 1
  local uses_delay = false

  for index, segment in ipairs(sequence.segments) do
    local data = converter:convert(segment, index)
    local pattern_index = pattern_by_key[data.key]

    if not pattern_index then
      if index == 1 then
        pattern_index = sequencer.pattern_sequence[1]
      else
        pattern_index = sequencer:insert_new_pattern_at(index)
      end
      local pattern = rns.patterns[pattern_index]
      pattern:clear()
      pattern.name = pattern_name(segment)
      pattern.number_of_lines = data.number_of_lines
      for channel = 1, SongSetup.CHANNEL_COUNT do
        write_track(pattern:track(channel), data.channels[channel])
      end
      pattern_by_key[data.key] = pattern_index
      pattern_count = pattern_count + 1
      max_effect_columns = math.max(max_effect_columns, data.effect_columns)
      uses_delay = uses_delay or data.uses_delay
    elseif index == 1 then
      sequencer:set_pattern(1, pattern_index)
    else
      sequencer:insert_sequence_at(index, pattern_index)
    end

    ProcessSlicer.step(('Pattern %d of %d'):format(index, #sequence.segments))
  end

  for channel = 1, SongSetup.CHANNEL_COUNT do
    local track = rns.tracks[channel]
    track.visible_effect_columns = math.min(8, max_effect_columns)
    track.delay_column_visible = uses_delay
  end

  if sequence.loop_to and #sequence.segments > 0 then
    rns.transport.loop_sequence_range = { sequence.loop_to, #sequence.segments }
  end

  return {
    patterns = pattern_count,
    sequence_length = #sequence.segments,
    loop_to = sequence.loop_to,
    truncated = sequence.truncated,
  }
end

return PatternWriter
