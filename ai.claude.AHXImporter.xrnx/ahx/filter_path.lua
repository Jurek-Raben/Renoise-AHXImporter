-- Renoise-filter path of the hybrid filter strategy (no Renoise API here).
--
-- Baked filter sweeps switch the sample on every filter step, and every switch is a new note in Renoise, which sounds
-- rough. When an instrument's filter stays on one side (only low-pass or only high-pass positions, 32 = open), the
-- filter is done by the Renoise filter instead: unfiltered samples, a low-/high-pass filter in the modulation sets and
-- the cutoff per frame as automation of the instrument's filter macro (see `PatternConverter:advance_volume`).
--
-- The AHX filter is a state variable filter run over the waveform data at the playback rate of the voice
-- (`AHXWaves.filter`), so its cutoff follows the pitch: with the coefficient f = (8 + 3 · step) · 1.25 / 100 of a
-- filter set, the cutoff is fc = fs · asin(f / 2) / π, fs = 3579545.25 / period.

local Tables = require('ahx.tables')
local Waves = require('ahx.waves')

local FilterPath = {}

local MIN_PERIOD = 0x0071
local MAX_PERIOD = 0x0d60

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

---Decides whether an instrument can use the Renoise filter: all filter positions of its simulations stay on one side
---(low-pass or high-pass; 32 = open). The cutoff is automated per frame (filter macro), so sample switches during
---the note (waveform, pulse width, pitch) do not matter.
---@param simulations AhxSimulation[]
---@return 'low'|'high'|nil side nil when the filter has to be baked (or there is no filter)
function FilterPath.analyze(simulations)
  local low, high = false, false
  for _, simulation in ipairs(simulations) do
    for _, frame in ipairs(simulation.frames) do
      local set = Waves.filter_set_of(frame.filter_pos)
      low = low or set < Waves.UNFILTERED_SET
      high = high or set > Waves.UNFILTERED_SET
    end
  end
  if low == high then
    return nil
  end
  return low and 'low' or 'high'
end

---Cutoff of a frame in Hz (false = filter open on this side): the AHX filter at the playback rate of the frame's
---period (`performance note + track note - 1` plus track and performance portamento, like the replayer).
---@param frame AhxFrame
---@param side 'low'|'high'
---@param track_ahx_note integer track note with position transpose (AHX note 1..60)
---@param slide_period integer track portamento period (ignored by fixed notes)
---@return number|false
function FilterPath.cutoff(frame, side, track_ahx_note, slide_period)
  local ahx_note = frame.fixed and frame.instr_period or frame.instr_period + track_ahx_note - 1
  local offset = frame.perf_slide_period + (frame.fixed and 0 or slide_period)
  local period = clamp(Tables.PERIODS[clamp(ahx_note, 0, 60)] + offset, MIN_PERIOD, MAX_PERIOD)
  local sample_rate = Tables.PAULA_CLOCK / period

  local set = Waves.filter_set_of(frame.filter_pos)
  local step = nil
  if side == 'low' and set < Waves.UNFILTERED_SET then
    step = set
  elseif side == 'high' and set > Waves.UNFILTERED_SET then
    step = set - Waves.UNFILTERED_SET - 1
  end
  if not step then
    return false
  end
  local coefficient = (8 + 3 * step) * 1.25 / 100
  return sample_rate * math.asin(math.min(1, coefficient / 2)) / math.pi
end

return FilterPath
