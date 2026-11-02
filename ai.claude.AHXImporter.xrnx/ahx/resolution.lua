-- Pattern resolution (pattern lines per AHX row) and the 0Vxy vibrato speed that depends on it.
--
-- Renoise's vibrato rate is proportional to x · lines per second, while the AHX vibrato has a fixed rate (vibrato
-- speed / 64 per frame). So x = vibrato speed · song speed / (6 · lines per row), calibrated by ear (xeron - 64k is
-- all you need: vibrato speed 8, song speed 3, 1× → x = 4; pink - thanatos remix: vibrato speed 9, song speed 16,
-- 2× → x = 12). x cannot exceed F; at 1× thanatos would need x = 24 and its vibrato was too slow. The automatic
-- resolution therefore is the smallest one where no vibrato needs x above F.

local bit = require('bit')

local Sequence = require('ahx.sequence')

local Resolution = {}

local DIVISOR = 6
local MAX_X = 15
local CHOICES = { 1, 2, 4 }
local INITIAL_SPEED = 6

---Unclamped 0Vxy speed for an AHX vibrato speed.
---@param vibrato_speed integer
---@param song_speed integer
---@param lines_per_row integer
---@return number
local function exact_speed(vibrato_speed, song_speed, lines_per_row)
  return bit.band(vibrato_speed, 0x3f) * song_speed / (DIVISOR * lines_per_row)
end

---0Vxy speed (x, rounded, may exceed F; the caller clamps).
---@param vibrato_speed integer
---@param song_speed integer
---@param lines_per_row integer
---@return integer
function Resolution.vibrato_speed(vibrato_speed, song_speed, lines_per_row)
  return math.floor(exact_speed(vibrato_speed, song_speed, lines_per_row) + 0.5)
end

---Smallest pattern resolution at which no triggered vibrato instrument needs x above F.
---@param song AhxSong
---@param subsong integer
---@return integer lines_per_row 1, 2 or 4
---@return number highest_x the highest x needed at 1×
function Resolution.auto(song, subsong)
  local sequence = Sequence.build(song, subsong)
  local speed = INITIAL_SPEED
  local highest = 0

  for _, segment in ipairs(sequence.segments) do
    local position = song.positions[segment.position]
    for row = segment.first_row, segment.last_row do
      for channel = 0, 3 do
        local step = song.tracks[position.track[channel]][row]
        if step.fx == 0xf and step.fx_param > 0 then
          speed = step.fx_param
        end
      end
      for channel = 0, 3 do
        local step = song.tracks[position.track[channel]][row]
        local instrument = step.instrument > 0 and song.instruments[step.instrument]
        if instrument and instrument.vibrato_depth > 0 and instrument.vibrato_speed > 0 then
          highest = math.max(highest, exact_speed(instrument.vibrato_speed, speed, 1))
        end
      end
    end
  end

  for _, choice in ipairs(CHOICES) do
    if math.floor(highest / choice + 0.5) <= MAX_X then
      return choice, highest
    end
  end
  return CHOICES[#CHOICES], highest
end

return Resolution
