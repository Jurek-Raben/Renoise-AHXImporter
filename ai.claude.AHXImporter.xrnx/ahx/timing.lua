-- Maps AHX speeds (frames per row) to Renoise timing.
--
-- One AHX frame is 1 / (50 · speed multiplier) s. Phrases play one line per frame, and a phrase's line rate depends
-- only on the song BPM (phrase LPB is fixed per phrase). So the BPM stays constant for the whole song and speed
-- changes only change LPB and TPL:
--   phrase LPB = 3000 · speed multiplier / BPM   (one phrase line = one frame)
--   song LPB   = phrase LPB / speed               (one pattern line = one AHX row)
--   TPL        = speed                            (one tick = one frame)

local Timing = {}

local PREFERRED_PHRASE_LPB = 24
local MAX_PHRASE_LPB = 256
local MIN_BPM = 32
local MAX_BPM = 999
local MAX_TPL = 16
local INITIAL_SPEED = 6

---@param a integer
---@param b integer
---@return integer
local function gcd(a, b)
  while b ~= 0 do
    a, b = b, a % b
  end
  return a
end

---@class AhxTimingPlan
---@field bpm number constant song BPM
---@field phrase_lpb integer
---@field speed_multiplier integer
---@field exact boolean false when some speeds can only be approximated

---Collects all speeds a song can use (the initial speed 6 and every Fxx with xx > 0).
---@param song AhxSong
---@return integer[]
local function used_speeds(song)
  local seen = { [INITIAL_SPEED] = true }
  local speeds = { INITIAL_SPEED }
  for track = 0, song.track_count do
    local steps = song.tracks[track]
    for row = 0, song.track_length - 1 do
      local step = steps[row]
      if step.fx == 0xf and step.fx_param > 0 and not seen[step.fx_param] then
        seen[step.fx_param] = true
        speeds[#speeds + 1] = step.fx_param
      end
    end
  end
  return speeds
end

---Chooses BPM and phrase LPB so that every used speed gets an integer song LPB.
---@param song AhxSong
---@return AhxTimingPlan
function Timing.plan(song)
  local multiplier = song.speed_multiplier
  local common = 1
  for _, speed in ipairs(used_speeds(song)) do
    common = common * speed / gcd(common, speed)
    if common > MAX_PHRASE_LPB then
      break
    end
  end

  local best = nil
  if common <= MAX_PHRASE_LPB then
    for phrase_lpb = common, MAX_PHRASE_LPB, common do
      local bpm = 3000 * multiplier / phrase_lpb
      if bpm >= MIN_BPM and bpm <= MAX_BPM then
        local integer_bpm = bpm == math.floor(bpm)
        local score = (integer_bpm and 0 or 1000) + math.abs(phrase_lpb - PREFERRED_PHRASE_LPB)
        if not best or score < best.score then
          best = { phrase_lpb = phrase_lpb, bpm = bpm, score = score }
        end
      end
    end
  end

  if not best then
    -- The speeds have no common multiple in range: frames stay exact, rows of unusual speeds are approximated.
    return {
      bpm = 3000 * multiplier / PREFERRED_PHRASE_LPB,
      phrase_lpb = PREFERRED_PHRASE_LPB,
      speed_multiplier = multiplier,
      exact = false,
    }
  end

  -- ASSUMPTION: transport.bpm accepts fractional values (only used when no integer BPM fits).
  return { bpm = best.bpm, phrase_lpb = best.phrase_lpb, speed_multiplier = multiplier, exact = true }
end

---Song LPB and TPL for a speed. With `lines_per_row` > 1 one AHX row spans several pattern lines (pattern
---resolution option): LPB is multiplied and TPL divided, so a tick stays one frame when the speed is divisible.
---@param plan AhxTimingPlan
---@param speed integer 1..255
---@param lines_per_row integer|nil 1, 2 or 4 (default 1)
---@return integer lpb
---@return integer tpl
---@return boolean exact
function Timing.for_speed(plan, speed, lines_per_row)
  lines_per_row = lines_per_row or 1
  local lpb = plan.phrase_lpb * lines_per_row / speed
  local rounded_lpb = math.max(1, math.min(255, math.floor(lpb + 0.5)))
  local tpl = speed / lines_per_row
  local rounded_tpl = math.max(1, math.min(MAX_TPL, math.floor(tpl + 0.5)))
  return rounded_lpb, rounded_tpl, rounded_lpb == lpb and rounded_tpl == tpl
end

Timing.INITIAL_SPEED = INITIAL_SPEED

return Timing
