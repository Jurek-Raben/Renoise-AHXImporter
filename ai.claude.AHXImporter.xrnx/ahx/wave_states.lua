-- Collects the distinct waveform states (waveform, filter set, pulse width) of the simulated notes of an instrument
-- (the plain note and its 9xx variants). Each state becomes one sample of the instrument.

local bit = require('bit')

local Waves = require('ahx.waves')

local WaveStates = {}

-- Phrases address samples via the instrument column (00..FE).
WaveStates.MAX_STATES = 255

---@class AhxWaveState
---@field waveform integer 0..3
---@field filter_pos integer 1..63
---@field square_pos integer voice square position (only relevant for squares)
---@field wave_length integer 0..7

---@class AhxWaveStateSet
---@field states AhxWaveState[] distinct states in order of first use
---@field frame_states integer[][] state index per simulated frame, per simulation
---@field filter_step integer filter set quantization that was needed to stay within MAX_STATES (1 = exact)

---Filter position with the filter sets quantized to every `step`-th set (low- and high-pass separately).
---@param filter_pos integer
---@param step integer
---@return integer
local function quantize_filter(filter_pos, step)
  local set = Waves.filter_set_of(filter_pos)
  if step <= 1 or set == Waves.UNFILTERED_SET then
    return set + 1
  end
  local first = set < Waves.UNFILTERED_SET and 0 or Waves.UNFILTERED_SET + 1
  return first + math.floor((set - first) / step) * step + 1
end

---Key that identifies audibly identical states.
---@param state AhxWaveState
---@return string
local function state_key(state)
  local square_width = 0
  if state.waveform == Waves.SQUARE then
    square_width = Waves.square_width_of(state.square_pos, math.min(state.wave_length, 5))
  end
  return table.concat({ state.waveform, Waves.filter_set_of(state.filter_pos), square_width }, ':')
end

---@param simulations AhxSimulation[]
---@param wave_length integer
---@param step integer
---@return AhxWaveStateSet
local function collect_with_step(simulations, wave_length, step)
  local result = { states = {}, frame_states = {}, filter_step = step }
  local index_by_key = {}
  for simulation_index, simulation in ipairs(simulations) do
    local frame_states = {}
    result.frame_states[simulation_index] = frame_states
    for frame, data in ipairs(simulation.frames) do
      local state = {
        waveform = data.waveform,
        filter_pos = quantize_filter(data.filter_pos, step),
        square_pos = data.square_pos,
        wave_length = wave_length,
      }
      local key = state_key(state)
      local index = index_by_key[key]
      if not index then
        index = #result.states + 1
        index_by_key[key] = index
        result.states[index] = state
      end
      frame_states[frame] = index
    end
  end
  return result
end

---Collects the states of the simulations, coarsening the filter resolution when there are too many.
---@param simulations AhxSimulation[]
---@param wave_length integer
---@return AhxWaveStateSet
function WaveStates.collect(simulations, wave_length)
  local step = 1
  local result = collect_with_step(simulations, wave_length, step)
  while #result.states > WaveStates.MAX_STATES and step < 31 do
    step = step + 1
    result = collect_with_step(simulations, wave_length, step)
  end
  return result
end

---Readable name of a waveform state, used for sample names.
---@param state AhxWaveState
---@return string
function WaveStates.describe(state)
  local names = { [0] = 'Triangle', 'Sawtooth', 'Square', 'Noise' }
  local wave_length = math.min(state.wave_length, 5)
  local parts = { names[state.waveform] or '?' }

  if state.waveform ~= Waves.NOISE then
    parts[#parts + 1] = ('%02X'):format(bit.lshift(4, wave_length))
  end
  if state.waveform == Waves.SQUARE then
    parts[#parts + 1] = ('W%02d'):format(Waves.square_width_of(state.square_pos, wave_length) + 1)
  end

  local set = Waves.filter_set_of(state.filter_pos)
  if set < Waves.UNFILTERED_SET then
    parts[#parts + 1] = ('LP%02d'):format(set + 1)
  elseif set > Waves.UNFILTERED_SET then
    parts[#parts + 1] = ('HP%02d'):format(set - Waves.UNFILTERED_SET)
  end
  return table.concat(parts, ' ')
end

return WaveStates
