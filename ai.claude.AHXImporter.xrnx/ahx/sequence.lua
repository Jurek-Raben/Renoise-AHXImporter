-- Flattens the AHX play order (position list, position jumps, pattern breaks) into a linear list of segments.
-- A segment is one position played from a start row to an end row; it becomes one Renoise pattern.
-- Mirrors the jump logic of `PlayIRQ` / `ProcessStep` (commands 0, B, D and speed 0).

local bit = require('bit')

local Sequence = {}

-- Renoise allows at most 1000 sequence slots.
local MAX_SEGMENTS = 1000

---@class AhxSegment
---@field position integer 0-based position number
---@field first_row integer 0-based
---@field last_row integer 0-based, inclusive

---@class AhxSequence
---@field segments AhxSegment[]
---@field loop_to integer|nil 1-based segment index the song loops back to, nil when it stops
---@field truncated boolean the segment limit was reached

---Decimal value of a BCD-like parameter (AHX uses decimal digits for B and D).
---@param param integer
---@return integer
local function decimal(param)
  return bit.rshift(param, 4) * 10 + bit.band(param, 0x0f)
end

---Builds the segment list of a subsong.
---@param song AhxSong
---@param subsong integer 0 = main song
---@return AhxSequence
function Sequence.build(song, subsong)
  local result = { segments = {}, loop_to = nil, truncated = false }
  if song.position_count == 0 or song.track_length == 0 then
    return result
  end

  local position = 0
  if subsong > 0 then
    position = song.subsongs[subsong] or 0
  end
  local row = 0
  local visited = {}

  while true do
    if position >= song.position_count then
      position = song.position_count - 1
    end

    local key = position .. ':' .. row
    if visited[key] then
      result.loop_to = visited[key]
      break
    end
    if #result.segments >= MAX_SEGMENTS then
      result.truncated = true
      break
    end
    visited[key] = #result.segments + 1

    local tracks = song.positions[position].track
    local first_row = row
    local last_row = song.track_length - 1
    local next_position = position + 1
    local next_row = 0
    local stopped = false
    local pos_jump = 0

    for current_row = first_row, song.track_length - 1 do
      local pattern_break = false
      local jump_row = 0

      for channel = 0, 3 do
        local step = song.tracks[tracks[channel]][current_row]
        local fx = step.fx
        local param = step.fx_param
        if fx == 0x0 then
          local high = bit.band(param, 0x0f)
          if high > 0 and high <= 9 then
            pos_jump = high
          end
        elseif fx == 0xb then
          pos_jump = pos_jump * 100 + decimal(param)
          pattern_break = true
        elseif fx == 0xd then
          pos_jump = position + 1
          jump_row = decimal(param)
          if jump_row > song.track_length then
            jump_row = 0
          end
          pattern_break = true
        elseif fx == 0xf and param == 0 then
          stopped = true
        end
      end

      if pattern_break or stopped then
        last_row = current_row
        next_position = pos_jump
        next_row = jump_row
        break
      end
    end

    result.segments[#result.segments + 1] = { position = position, first_row = first_row, last_row = last_row }

    if stopped then
      break
    end
    if next_position == song.position_count then
      -- Song end: the replayer continues at the restart position.
      next_position = song.restart
      next_row = 0
    end
    if next_row >= song.track_length then
      next_row = 0
    end

    position = next_position
    row = next_row
  end

  return result
end

return Sequence
