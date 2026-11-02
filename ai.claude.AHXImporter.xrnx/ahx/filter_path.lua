-- Renoise-filter path of the hybrid filter strategy (no Renoise API here).
--
-- Baked filter sweeps switch the sample on every filter step, and every switch is a new note in Renoise, which sounds
-- rough. When an instrument's filter stays on one side (only low-pass or only high-pass positions, 32 = open) and
-- nothing else changes the sample during a note, the filter is done by the Renoise filter instead: one unfiltered
-- sample per phrase and a cutoff envelope with one point per frame.
--
-- The AHX filter is a state variable filter run over the waveform data at the playback rate of the voice
-- (`AHXWaves.filter`), so its cutoff follows the pitch: with the coefficient f = (8 + 3 · step) · 1.25 / 100 of a
-- filter set, the cutoff is fc = fs · asin(f / 2) / π, fs = 3579545.25 / period.

local NoteUsage = require('ahx.note_usage')
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

---Decides whether an instrument can use the Renoise filter.
---@param simulations AhxSimulation[]
---@param wave_length integer
---@return 'low'|'high'|nil side nil when the filter has to be baked (or there is no filter)
function FilterPath.analyze(simulations, wave_length)
  local low, high = false, false
  local wave = math.min(wave_length, 5)
  for _, simulation in ipairs(simulations) do
    local first = simulation.frames[1]
    for _, frame in ipairs(simulation.frames) do
      local set = Waves.filter_set_of(frame.filter_pos)
      low = low or set < Waves.UNFILTERED_SET
      high = high or set > Waves.UNFILTERED_SET
      -- Any other sample change during the note would retrigger the sample and restart the cutoff envelope.
      local same_wave = frame.waveform == first.waveform
        and (
          frame.waveform ~= Waves.SQUARE
          or Waves.square_width_of(frame.square_pos, wave) == Waves.square_width_of(first.square_pos, wave)
        )
      if not same_wave or frame.perf_slide_period ~= 0 then
        return nil
      end
    end
  end
  if low == high then
    return nil
  end
  return low and 'low' or 'high'
end

---@class AhxCutoffEnvelope
---@field cutoffs (number|false)[] cutoff in Hz per frame, false = filter open
---@field loop_start integer|nil 1-based frame
---@field loop_end integer|nil

---Cutoff per frame of a simulated note played at a trigger note.
---@param simulation AhxSimulation
---@param side 'low'|'high'
---@param trigger_note integer Renoise note
---@return AhxCutoffEnvelope
function FilterPath.envelope(simulation, side, trigger_note)
  local result = { cutoffs = {} }
  local track_ahx_note = trigger_note - NoteUsage.NOTE_OFFSET
  for index, frame in ipairs(simulation.frames) do
    local ahx_note = frame.fixed and frame.instr_period or frame.instr_period + track_ahx_note - 1
    local period = clamp(Tables.PERIODS[clamp(ahx_note, 0, 60)] + frame.perf_slide_period, MIN_PERIOD, MAX_PERIOD)
    local sample_rate = Tables.PAULA_CLOCK / period

    local set = Waves.filter_set_of(frame.filter_pos)
    local step = nil
    if side == 'low' and set < Waves.UNFILTERED_SET then
      step = set
    elseif side == 'high' and set > Waves.UNFILTERED_SET then
      step = set - Waves.UNFILTERED_SET - 1
    end
    if step then
      local coefficient = (8 + 3 * step) * 1.25 / 100
      result.cutoffs[index] = sample_rate * math.asin(math.min(1, coefficient / 2)) / math.pi
    else
      result.cutoffs[index] = false
    end
  end
  if simulation.loop_start and simulation.loop_end > simulation.loop_start then
    result.loop_start = simulation.loop_start
    result.loop_end = simulation.loop_end
  end
  return result
end

return FilterPath
