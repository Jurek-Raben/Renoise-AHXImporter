-- AHX waveform tables. Port of `AHXWaves` of the reference replayer, plus the voice buffer construction of
-- `ProcessFrame` / `SetAudio`.
--
-- Filter sets are indexed 0..62 like in the original: 0..30 low-pass (cutoff rising), 31 unfiltered, 32..62 high-pass
-- (cutoff rising). Sets are generated lazily on first use. Waveform data are 1-based Lua arrays of signed 8-bit
-- values (-128..127).
--
-- Voice waveform numbers (0-based like the replayer's `Voice.Waveform`): 0 = triangle, 1 = sawtooth, 2 = square,
-- 3 = white noise.

local bit = require('bit')

local NoiseData = require('ahx.noise_data')
local Tables = require('ahx.tables')

local Waves = {}

Waves.TRIANGLE = 0
Waves.SAWTOOTH = 1
Waves.SQUARE = 2
Waves.NOISE = 3

Waves.UNFILTERED_SET = 31

local NOISE_LENGTH = 0x280 * 3
local SQUARE_BLOCK = 0x80
local SQUARE_COUNT = 0x20

---@class AhxWaveSet
---@field triangle table<integer, number[]> by wave length 0..5
---@field sawtooth table<integer, number[]> by wave length 0..5
---@field squares number[] 0x20 pulse widths of 0x80 frames each
---@field noise number[] 0x280 * 3 frames

---@type table<integer, AhxWaveSet>
local filter_sets = {}

---@param length integer
---@return number[]
local function generate_triangle(length)
  local buffer = {}
  local d5 = bit.rshift(length, 2)
  local d1 = 128 / d5
  local d4 = -bit.rshift(length, 1)

  local eax = 0
  for _ = 1, d5 do
    buffer[#buffer + 1] = eax
    eax = eax + d1
  end
  buffer[#buffer + 1] = 0x7f
  if d5 ~= 1 then
    eax = 128
    for _ = 1, d5 - 1 do
      eax = eax - d1
      buffer[#buffer + 1] = eax
    end
  end

  -- Second half: the first half mirrored (0-based read index `esi` of the original).
  local esi = #buffer + d4
  for _ = 1, d5 * 2 do
    local value = buffer[esi + 1]
    esi = esi + 1
    if value == 0x7f then
      value = -0x80
    else
      value = -value
    end
    buffer[#buffer + 1] = value
  end
  return buffer
end

---@return number[]
local function generate_squares()
  local buffer = {}
  for width = 1, SQUARE_COUNT do
    for _ = 1, (0x40 - width) * 2 do
      buffer[#buffer + 1] = -0x80
    end
    for _ = 1, width * 2 do
      buffer[#buffer + 1] = 0x7f
    end
  end
  return buffer
end

---@param length integer
---@return number[]
local function generate_sawtooth(length)
  local buffer = {}
  local step = math.floor(256 / (length - 1))
  local value = -128
  for _ = 1, length do
    buffer[#buffer + 1] = value
    value = value + step
  end
  return buffer
end

---@return number[]
local function generate_noise()
  local buffer = {}
  for i = 1, NOISE_LENGTH do
    local value = NoiseData[i]
    if value >= 0x80 then
      value = value - 0x100 -- signed char
    end
    buffer[i] = value
  end
  return buffer
end

---Clamps to the signed 8-bit range like the original filter.
---@param value number
---@return number
local function clamp8(value)
  if value > 127 then
    return 127
  elseif value < -128 then
    return -128
  end
  return value
end

---State-variable filter over one periodic waveform: a warm-up pass, then the real pass.
---@param input number[]
---@param first integer 1-based start index in `input`
---@param count integer number of frames
---@param fre number filter coefficient
---@param high_pass boolean
---@param output number[] appended to
local function filter(input, first, count, fre, high_pass, output)
  local high
  local mid = 0.0
  local low = 0.0
  local last = first + count - 1

  for i = first, last do
    high = clamp8(input[i] - mid - low)
    mid = clamp8(mid + high * fre)
    low = clamp8(low + mid * fre)
  end

  for i = first, last do
    high = clamp8(input[i] - mid - low)
    mid = clamp8(mid + high * fre)
    low = clamp8(low + mid * fre)
    output[#output + 1] = math.floor(high_pass and high or low)
  end
end

---@param input number[]
---@param fre number
---@param high_pass boolean
---@return number[]
local function filter_whole(input, fre, high_pass)
  local output = {}
  filter(input, 1, #input, fre, high_pass, output)
  return output
end

---@return AhxWaveSet
local function generate_unfiltered_set()
  local set = { triangle = {}, sawtooth = {}, squares = generate_squares(), noise = generate_noise() }
  for wave_length = 0, 5 do
    local length = bit.lshift(4, wave_length)
    set.triangle[wave_length] = generate_triangle(length)
    set.sawtooth[wave_length] = generate_sawtooth(length)
  end
  return set
end

---@param index integer 0..30 (low-pass) or 32..62 (high-pass)
---@return AhxWaveSet
local function generate_filtered_set(index)
  local source = Waves.get_set(Waves.UNFILTERED_SET)
  local high_pass = index > Waves.UNFILTERED_SET
  local step = high_pass and index - 32 or index
  local fre = ((8 + 3 * step) * 1.25) / 100.0

  local set = { triangle = {}, sawtooth = {}, squares = {}, noise = filter_whole(source.noise, fre, high_pass) }
  for wave_length = 0, 5 do
    set.triangle[wave_length] = filter_whole(source.triangle[wave_length], fre, high_pass)
    set.sawtooth[wave_length] = filter_whole(source.sawtooth[wave_length], fre, high_pass)
  end
  -- Each pulse width is filtered as its own periodic block.
  for block = 0, SQUARE_COUNT - 1 do
    filter(source.squares, block * SQUARE_BLOCK + 1, SQUARE_BLOCK, fre, high_pass, set.squares)
  end
  return set
end

---Returns a filter set, generating it on first use.
---@param index integer 0..62
---@return AhxWaveSet
function Waves.get_set(index)
  local set = filter_sets[index]
  if not set then
    if index == Waves.UNFILTERED_SET then
      set = generate_unfiltered_set()
    else
      set = generate_filtered_set(index)
    end
    filter_sets[index] = set
  end
  return set
end

---Filter set of a voice filter position (port of `FilterSetOf` without the live cutoff factor).
---@param filter_pos integer 1..63, 32 = unfiltered
---@return integer
function Waves.filter_set_of(filter_pos)
  local set = filter_pos - 1
  if set < 0 then
    return 0
  elseif set > 62 then
    return 62
  end
  return set
end

---Effective pulse width index of a square position, as the replayer folds it (0..31; positions 0 and 1 are equal).
---@param square_pos integer voice square position (already shifted by the wave length)
---@param wave_length integer 0..5
---@return integer
function Waves.square_width_of(square_pos, wave_length)
  local x = bit.lshift(square_pos, 5 - wave_length)
  if x > 0x20 then
    x = 0x40 - x
  end
  if x > 0 then
    x = x - 1
  end
  return x
end

---Builds one waveform cycle like `ProcessFrame` does (the `AudioSource`).
---@param waveform integer 0..2 (noise has no cycle, see `Waves.voice_buffer`)
---@param filter_pos integer 1..63
---@param wave_length integer 0..7 (6 and 7 are invalid and give an empty cycle, like the original)
---@param square_pos integer only used for squares
---@return number[]
function Waves.cycle(waveform, filter_pos, wave_length, square_pos)
  local set = Waves.get_set(Waves.filter_set_of(filter_pos))
  if wave_length > 5 then
    return {}
  end

  if waveform == Waves.SQUARE then
    local cycle = {}
    local offset = Waves.square_width_of(square_pos, wave_length) * SQUARE_BLOCK
    local delta = bit.rshift(32, wave_length)
    local length = bit.lshift(1, wave_length) * 4
    for i = 1, length do
      cycle[i] = set.squares[offset + 1]
      offset = offset + delta
    end
    return cycle
  elseif waveform == Waves.SAWTOOTH then
    return set.sawtooth[wave_length]
  end
  return set.triangle[wave_length]
end

---Builds the sample data of a waveform state: the cycle repeated to `Tables.SAMPLE_BUFFER_LENGTH` frames, or the whole
---filtered noise table for white noise. The replayer repeats the cycle to 0x280 frames; 256 frames hold a whole number
---of cycles for every wave length as well and let a sample offset (0Sxx = xx/256 of the sample) address every frame.
---@param waveform integer 0..3
---@param filter_pos integer 1..63
---@param wave_length integer 0..7
---@param square_pos integer
---@return number[] frames signed 8-bit values
---@return integer cycle_length frames per waveform cycle (the noise table length for noise)
function Waves.voice_buffer(waveform, filter_pos, wave_length, square_pos)
  if waveform == Waves.NOISE then
    local noise = Waves.get_set(Waves.filter_set_of(filter_pos)).noise
    return noise, #noise
  end

  local buffer = {}
  local cycle = Waves.cycle(waveform, filter_pos, wave_length, square_pos)
  local cycle_length = #cycle
  if cycle_length == 0 then
    for i = 1, Tables.SAMPLE_BUFFER_LENGTH do
      buffer[i] = 0
    end
    return buffer, Tables.SAMPLE_BUFFER_LENGTH
  end

  for i = 1, Tables.SAMPLE_BUFFER_LENGTH do
    buffer[i] = cycle[(i - 1) % cycle_length + 1]
  end
  return buffer, cycle_length
end

return Waves
