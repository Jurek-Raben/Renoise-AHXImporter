-- Prepares a fresh song for the import: four sequencer tracks for the four AHX voices, no send tracks, one empty
-- instrument (reused as AHX instrument 01) and an empty sequence.

local Util = require('importer.util')

local SongSetup = {}

-- Limiter on the master, so four full-scale chip voices do not clip.
local MAXIMIZER_THRESHOLD = '-0.5 dB'

-- Amiga channel layout L R R L, softened to 75 % stereo separation.
local PANNING = { 0.25, 0.75, 0.75, 0.25 }

local CHANNEL_COUNT = 4

---@param rns renoise.Song
local function setup_tracks(rns)
  -- Remove send and group tracks, then trim/extend the sequencer tracks to four.
  for index = #rns.tracks, 1, -1 do
    local track_type = rns.tracks[index].type
    if track_type == renoise.Track.TRACK_TYPE_SEND or track_type == renoise.Track.TRACK_TYPE_GROUP then
      rns:delete_track_at(index)
    end
  end
  while rns.sequencer_track_count > CHANNEL_COUNT do
    rns:delete_track_at(rns.sequencer_track_count)
  end
  while rns.sequencer_track_count < CHANNEL_COUNT do
    rns:insert_track_at(rns.sequencer_track_count + 1)
  end

  for channel = 1, CHANNEL_COUNT do
    local track = rns.tracks[channel]
    track.name = ('AHX %d'):format(channel)
    track.prefx_panning.value = PANNING[channel]
    track.volume_column_visible = true
  end
end

---@param rns renoise.Song
local function setup_instruments(rns)
  while #rns.instruments > 1 do
    rns:delete_instrument_at(#rns.instruments)
  end
  rns.instruments[1]:clear()
end

---@param rns renoise.Song
local function setup_sequence(rns)
  local sequencer = rns.sequencer
  while #sequencer.pattern_sequence > 1 do
    sequencer:delete_sequence_at(#sequencer.pattern_sequence)
  end
  rns.patterns[sequencer.pattern_sequence[1]]:clear()
end

---Adds a Maximizer to the master track. Failures are logged, not fatal.
---@param rns renoise.Song
local function setup_master(rns)
  local master = rns.tracks[rns.sequencer_track_count + 1]
  local path = nil
  for _, candidate in ipairs(master.available_devices) do
    if candidate:find('Maximizer', 1, true) then
      path = candidate
      break
    end
  end
  if not path then
    Util.log('Master: no Maximizer device available')
    return
  end

  local maximizer = master:insert_device_at(path, #master.devices + 1)
  local ok, message = pcall(function()
    -- ASSUMPTION: the threshold accepts a value string in dB.
    Util.parameter(maximizer, 'Threshold').value_string = MAXIMIZER_THRESHOLD
  end)
  if ok then
    Util.log('Master: Maximizer -> %s', Util.describe_parameters(maximizer))
  else
    Util.log('Master: Maximizer threshold not set: %s (%s)', tostring(message), Util.describe_parameters(maximizer))
  end
end

---Normalizes the current song.
function SongSetup.prepare()
  local rns = renoise.song()
  setup_tracks(rns)
  setup_master(rns)
  setup_instruments(rns)
  setup_sequence(rns)
end

SongSetup.CHANNEL_COUNT = CHANNEL_COUNT

return SongSetup
