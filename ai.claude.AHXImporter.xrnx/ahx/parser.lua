-- AHX/THX song parser. Port of `AHXSong.parse` / `AHXSong.InitSong` of the reference replayer.
--
-- Index conventions (mirroring the original, documented here once):
--   * positions[0 .. position_count - 1], each with track[0..3] and transpose[0..3]
--   * tracks[0 .. track_count], each with steps[0 .. track_length - 1]
--   * instruments[0 .. instrument_count]; instruments[0] is the empty dummy instrument
--   * plist.entries[0 .. plist.length - 1]
--   * subsongs[1 .. subsong_count] = start positions of the additional subsongs

local bit = require('bit')

local Parser = {}

---@class AhxEnvelope
---@field a_frames integer
---@field a_volume integer
---@field d_frames integer
---@field d_volume integer
---@field s_frames integer
---@field r_frames integer
---@field r_volume integer

---@class AhxPlistEntry
---@field note integer 0 = no note, else relative (or fixed) AHX note
---@field fixed integer 1 = fixed note
---@field waveform integer 0 = keep, 1 = triangle, 2 = sawtooth, 3 = square, 4 = noise
---@field fx integer[] two commands, 0-based: fx[0], fx[1]
---@field fx_param integer[] two parameters, 0-based: fx_param[0], fx_param[1]

---@class AhxPlist
---@field speed integer
---@field length integer
---@field entries table<integer, AhxPlistEntry>

---@class AhxInstrument
---@field name string
---@field volume integer
---@field wave_length integer 0..5 (cycle length 4 << wave_length)
---@field envelope AhxEnvelope
---@field filter_lower_limit integer
---@field filter_upper_limit integer
---@field filter_speed integer
---@field square_lower_limit integer
---@field square_upper_limit integer
---@field square_speed integer
---@field vibrato_delay integer
---@field vibrato_depth integer
---@field vibrato_speed integer
---@field hard_cut_release integer
---@field hard_cut_release_frames integer
---@field plist AhxPlist

---@class AhxStep
---@field note integer
---@field instrument integer
---@field fx integer
---@field fx_param integer

---@class AhxPosition
---@field track table<integer, integer>
---@field transpose table<integer, integer>

---@class AhxSong
---@field name string
---@field revision integer 0 = THX0, 1 = THX1
---@field speed_multiplier integer 1..4 (replayer calls per 1/50 s)
---@field restart integer
---@field position_count integer
---@field track_length integer
---@field track_count integer highest track number (tracks 0..track_count exist)
---@field instrument_count integer
---@field subsong_count integer
---@field subsongs integer[]
---@field positions table<integer, AhxPosition>
---@field tracks table<integer, table<integer, AhxStep>>
---@field instruments table<integer, AhxInstrument>

---Reads a zero-terminated string.
---@param data string
---@param pos integer 0-based byte offset
---@return string
local function read_string_at(data, pos)
  local zero = data:find('\0', pos + 1, true)
  if not zero then
    return data:sub(pos + 1)
  end
  return data:sub(pos + 1, zero - 1)
end

---@return AhxInstrument
local function create_instrument()
  return {
    name = '',
    volume = 0,
    wave_length = 0,
    envelope = {
      a_frames = 0,
      a_volume = 0,
      d_frames = 0,
      d_volume = 0,
      s_frames = 0,
      r_frames = 0,
      r_volume = 0,
    },
    filter_lower_limit = 0,
    filter_upper_limit = 0,
    filter_speed = 0,
    square_lower_limit = 0,
    square_upper_limit = 0,
    square_speed = 0,
    vibrato_delay = 0,
    vibrato_depth = 0,
    vibrato_speed = 0,
    hard_cut_release = 0,
    hard_cut_release_frames = 0,
    plist = { speed = 0, length = 0, entries = {} },
  }
end

---Parses the bytes of an .ahx file (formats THX0/THX1).
---@param data string raw file content
---@return AhxSong|nil song
---@return string|nil error
function Parser.parse(data)
  if #data < 14 or data:sub(1, 3) ~= 'THX' then
    return nil, 'Not an AHX file ("THX" signature missing)'
  end

  -- Reads one unsigned byte at a 0-based offset; bytes past the end read as 0 (the original reads undefined & 0xff).
  local function byte_at(pos)
    return data:byte(pos + 1) or 0
  end

  local song = {
    revision = byte_at(3),
    subsongs = {},
    positions = {},
    tracks = {},
    instruments = {},
  }

  -- Header
  local name_ptr = bit.bor(bit.lshift(byte_at(4), 8), byte_at(5))
  song.name = read_string_at(data, name_ptr)
  song.speed_multiplier = bit.band(bit.rshift(byte_at(6), 5), 3) + 1
  song.position_count = bit.bor(bit.lshift(bit.band(byte_at(6), 0xf), 8), byte_at(7))
  song.restart = bit.bor(bit.lshift(byte_at(8), 8), byte_at(9))
  song.track_length = byte_at(10)
  song.track_count = byte_at(11)
  song.instrument_count = byte_at(12)
  song.subsong_count = byte_at(13)

  local sb_ptr = 14

  -- Subsongs
  for i = 1, song.subsong_count do
    song.subsongs[i] = bit.bor(bit.lshift(byte_at(sb_ptr), 8), byte_at(sb_ptr + 1))
    sb_ptr = sb_ptr + 2
  end

  -- Position list
  for i = 0, song.position_count - 1 do
    local position = { track = {}, transpose = {} }
    for j = 0, 3 do
      position.track[j] = byte_at(sb_ptr)
      local transpose = byte_at(sb_ptr + 1)
      if transpose >= 0x80 then
        transpose = transpose - 0x100 -- signed char
      end
      position.transpose[j] = transpose
      sb_ptr = sb_ptr + 2
    end
    song.positions[i] = position
  end

  -- Tracks (bit 7 of byte 6 set: track 0 is not stored and empty)
  local track_0_empty = bit.band(byte_at(6), 0x80) == 0x80
  for i = 0, song.track_count do
    local steps = {}
    if track_0_empty and i == 0 then
      for j = 0, song.track_length - 1 do
        steps[j] = { note = 0, instrument = 0, fx = 0, fx_param = 0 }
      end
    else
      for j = 0, song.track_length - 1 do
        local b0 = byte_at(sb_ptr)
        local b1 = byte_at(sb_ptr + 1)
        steps[j] = {
          note = bit.band(bit.rshift(b0, 2), 0x3f),
          instrument = bit.bor(bit.lshift(bit.band(b0, 0x3), 4), bit.rshift(b1, 4)),
          fx = bit.band(b1, 0xf),
          fx_param = byte_at(sb_ptr + 2),
        }
        sb_ptr = sb_ptr + 3
      end
    end
    song.tracks[i] = steps
  end

  -- Instruments; their names follow the song name in the name table.
  local current_name_ptr = name_ptr + #song.name + 1
  song.instruments[0] = create_instrument()

  for i = 1, song.instrument_count do
    local instrument = create_instrument()
    local envelope = instrument.envelope

    instrument.name = read_string_at(data, current_name_ptr)
    current_name_ptr = current_name_ptr + #instrument.name + 1

    instrument.volume = byte_at(sb_ptr)
    instrument.filter_speed = bit.bor(
      bit.band(bit.rshift(byte_at(sb_ptr + 1), 3), 0x1f),
      bit.band(bit.rshift(byte_at(sb_ptr + 12), 2), 0x20)
    )
    instrument.wave_length = bit.band(byte_at(sb_ptr + 1), 0x7)
    envelope.a_frames = byte_at(sb_ptr + 2)
    envelope.a_volume = byte_at(sb_ptr + 3)
    envelope.d_frames = byte_at(sb_ptr + 4)
    envelope.d_volume = byte_at(sb_ptr + 5)
    envelope.s_frames = byte_at(sb_ptr + 6)
    envelope.r_frames = byte_at(sb_ptr + 7)
    envelope.r_volume = byte_at(sb_ptr + 8)
    instrument.filter_lower_limit = bit.band(byte_at(sb_ptr + 12), 0x7f)
    instrument.vibrato_delay = byte_at(sb_ptr + 13)
    instrument.hard_cut_release_frames = bit.band(bit.rshift(byte_at(sb_ptr + 14), 4), 7)
    instrument.hard_cut_release = bit.band(byte_at(sb_ptr + 14), 0x80) ~= 0 and 1 or 0
    instrument.vibrato_depth = bit.band(byte_at(sb_ptr + 14), 0xf)
    instrument.vibrato_speed = byte_at(sb_ptr + 15)
    instrument.square_lower_limit = byte_at(sb_ptr + 16)
    instrument.square_upper_limit = byte_at(sb_ptr + 17)
    instrument.square_speed = byte_at(sb_ptr + 18)
    instrument.filter_upper_limit = bit.band(byte_at(sb_ptr + 19), 0x3f)
    instrument.plist.speed = byte_at(sb_ptr + 20)
    instrument.plist.length = byte_at(sb_ptr + 21)
    sb_ptr = sb_ptr + 22

    for j = 0, instrument.plist.length - 1 do
      local b0 = byte_at(sb_ptr)
      local b1 = byte_at(sb_ptr + 1)
      instrument.plist.entries[j] = {
        fx = {
          [0] = bit.band(bit.rshift(b0, 2), 7),
          [1] = bit.band(bit.rshift(b0, 5), 7),
        },
        waveform = bit.bor(bit.band(bit.lshift(b0, 1), 6), bit.rshift(b1, 7)),
        fixed = bit.band(bit.rshift(b1, 6), 1),
        note = bit.band(b1, 0x3f),
        fx_param = {
          [0] = byte_at(sb_ptr + 2),
          [1] = byte_at(sb_ptr + 3),
        },
      }
      sb_ptr = sb_ptr + 4
    end

    song.instruments[i] = instrument
  end

  return song
end

---Reads and parses an .ahx file from disk.
---@param file_name string
---@return AhxSong|nil song
---@return string|nil error
function Parser.parse_file(file_name)
  local file, open_error = io.open(file_name, 'rb')
  if not file then
    return nil, 'Cannot open file: ' .. tostring(open_error)
  end
  local data = file:read('*a')
  file:close()
  return Parser.parse(data)
end

return Parser
