-- Band-limited rendering of a waveform cycle (no Renoise API): the cycle is resynthesized from its harmonics, keeping
-- only those that stay below a cutoff at the highest pitch the sample is played at, so the waveform does not alias.
-- When harmonics are cut, the Gibbs ringing is softened with Lanczos sigma factors; when all fit, the cycle is
-- reconstructed exactly. The DC offset stays: removing it made narrow pulses peak far above the 8-bit range, and the
-- scaling back made them much quieter (mobby - good day, bass AHX 02).

local BandLimit = {}

-- Highest frequency kept (below the Nyquist frequency of 44.1 / 48 kHz output).
BandLimit.CUTOFF_HZ = 18000

---Harmonics of one cycle: DC plus cosine / sine amplitudes.
---@param cycle number[]
---@return number dc
---@return number[] cosines by harmonic 1..length/2
---@return number[] sines
local function harmonics(cycle)
  local length = #cycle
  local dc = 0
  for n = 1, length do
    dc = dc + cycle[n]
  end
  dc = dc / length

  local cosines, sines = {}, {}
  for k = 1, math.floor(length / 2) do
    local a, b = 0, 0
    for n = 1, length do
      local angle = 2 * math.pi * k * (n - 1) / length
      a = a + cycle[n] * math.cos(angle)
      b = b + cycle[n] * math.sin(angle)
    end
    local scale = (2 * k == length) and 1 / length or 2 / length
    cosines[k] = a * scale
    sines[k] = b * scale
  end
  return dc, cosines, sines
end

---Renders a band-limited buffer of whole cycles.
---@param cycle number[] one cycle, signed 8-bit values
---@param cycle_frequency number frequency of the cycle at the highest pitch it is played at (Hz)
---@param frames_per_cycle integer output frames per cycle
---@param cycles integer number of cycles in the output
---@return number[] frames signed 8-bit range (scaled down when the ringing would exceed it)
---@return integer kept harmonics
function BandLimit.render(cycle, cycle_frequency, frames_per_cycle, cycles)
  local dc, cosines, sines = harmonics(cycle)
  local count = math.min(#cosines, math.max(1, math.floor(BandLimit.CUTOFF_HZ / cycle_frequency)))
  local cut = count < #cosines

  -- Lanczos sigma factors against ringing, only when the series is cut.
  local sigma = {}
  for k = 1, count do
    if cut then
      local x = math.pi * k / (count + 1)
      sigma[k] = math.sin(x) / x
    else
      sigma[k] = 1
    end
  end

  local one_cycle, peak = {}, 0
  for i = 1, frames_per_cycle do
    local phase = 2 * math.pi * (i - 1) / frames_per_cycle
    local value = dc
    for k = 1, count do
      value = value + sigma[k] * (cosines[k] * math.cos(k * phase) + sines[k] * math.sin(k * phase))
    end
    one_cycle[i] = value
    peak = math.max(peak, math.abs(value))
  end

  local scale = peak > 127 and 127 / peak or 1
  local frames = {}
  for c = 0, cycles - 1 do
    for i = 1, frames_per_cycle do
      frames[c * frames_per_cycle + i] = one_cycle[i] * scale
    end
  end
  return frames, count
end

return BandLimit
