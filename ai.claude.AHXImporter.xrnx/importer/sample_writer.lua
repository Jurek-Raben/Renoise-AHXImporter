-- Writes AHX waveform buffers into Renoise samples.

local BandLimit = require('ahx.band_limit')
local Tables = require('ahx.tables')

local SampleWriter = {}

-- A sample plays at the rate of its tuning (`Tables.TUNINGS`) at its base note C-4. With PAL Paula, AHX note C-3 plays
-- at 3546895 / 856 ≈ 4143.6 Hz, AHX note n maps to Renoise note n + 11, so C-4 is one octave above: ≈ 8287.1 Hz.
local BASE_NOTE = 48

---Loop, interpolation and playback properties shared by all renderings.
---@param sample renoise.Sample
---@param name string
---@param options AhxImportOptions
---@param frame_count integer
local function apply_properties(sample, name, options, frame_count)
  sample.name = name
  sample.interpolation_mode = options.interpolation
  sample.oversample_enabled = options.oversample
  -- Every sample switch of a phrase is a new note; the previous one must stop at once (an AHX voice plays one
  -- waveform at a time). With "note off" as new note action, the release of the hard cut AHDSR let the old notes
  -- fade out underneath and modulated the volume (syphus - better days, bass on AHX 1).
  sample.new_note_action = renoise.Sample.NEW_NOTE_ACTION_NOTE_CUT
  sample.loop_mode = renoise.Sample.LOOP_MODE_FORWARD
  sample.loop_start = 1
  sample.loop_end = frame_count
  sample.transpose = 0
  sample.fine_tune = 0
  sample.sample_mapping.base_note = BASE_NOTE
end

-- Smoothed rendering needs frames in between to interpolate; at factor 1 it renders at this factor.
local SMOOTHED_MIN_FACTOR = 4

---Value between frames of a looped buffer (Catmull-Rom spline, wrapping around so the loop stays seamless).
---@param frames number[]
---@param position number 0-based position in frames
---@return number
local function cubic(frames, position)
  local count = #frames
  local base = math.floor(position)
  local t = position - base
  local p0 = frames[(base - 1) % count + 1]
  local p1 = frames[base % count + 1]
  local p2 = frames[(base + 1) % count + 1]
  local p3 = frames[(base + 2) % count + 1]
  return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
end

---Fills a sample with a looped waveform buffer.
---@param sample renoise.Sample
---@param frames number[] signed 8-bit values
---@param name string
---@param options AhxImportOptions interpolation, bit depth, sample rate factor and rendering
function SampleWriter.write(sample, frames, name, options)
  local buffer = sample.sample_buffer
  -- A higher sample rate keeps waveform and pitch, and 0Sxx (xx/256 of the length) still addresses the same frames of
  -- the original 256-frame buffer. Original rendering repeats every frame (sample and hold, like Paula); smoothed
  -- rendering interpolates between the frames, which rounds off the edges.
  local smoothed = options.rendering == 2
  local factor = options.sample_rate_factor
  if smoothed then
    factor = math.max(factor, SMOOTHED_MIN_FACTOR)
  end
  local frame_count = #frames * factor
  local sample_rate = Tables.TUNINGS[options.tuning].sample_rate

  if not buffer:create_sample_data(sample_rate * factor, options.bit_depth, 1, frame_count) then
    error('Out of memory while creating sample "' .. name .. '"')
  end

  buffer:prepare_sample_data_changes(false)
  for i = 1, frame_count do
    local value
    if smoothed then
      value = math.max(-128, math.min(127, cubic(frames, (i - 1) / factor)))
    else
      value = frames[math.floor((i - 1) / factor) + 1]
    end
    buffer:set_sample_data(1, i, value / 128)
  end
  buffer:finalize_sample_data_changes()

  apply_properties(sample, name, options, frame_count)
end

---Fills a sample with whole cycles resynthesized band-limited for the highest pitch they are played at (no aliasing).
---Same length and loop layout as the other renderings (256 original frames, at least 4× the rate), so the phase
---offsets (0Sxx) of the phrases stay valid.
---@param sample renoise.Sample
---@param cycle number[] one waveform cycle, signed 8-bit values
---@param top_pitch number highest Renoise note (with fine tune) the sample is played at
---@param name string
---@param options AhxImportOptions
function SampleWriter.write_band_limited(sample, cycle, top_pitch, name, options)
  local buffer = sample.sample_buffer
  local factor = math.max(options.sample_rate_factor, SMOOTHED_MIN_FACTOR)
  local cycle_length = #cycle
  local cycles = Tables.SAMPLE_BUFFER_LENGTH / cycle_length
  local sample_rate = Tables.TUNINGS[options.tuning].sample_rate
  local cycle_frequency = sample_rate * 2 ^ ((top_pitch - BASE_NOTE) / 12) / cycle_length
  local frames = BandLimit.render(cycle, cycle_frequency, cycle_length * factor, cycles, options.band_limit_roll_off)
  local frame_count = #frames

  if not buffer:create_sample_data(sample_rate * factor, options.bit_depth, 1, frame_count) then
    error('Out of memory while creating sample "' .. name .. '"')
  end
  buffer:prepare_sample_data_changes(false)
  for i = 1, frame_count do
    buffer:set_sample_data(1, i, frames[i] / 128)
  end
  buffer:finalize_sample_data_changes()

  apply_properties(sample, name, options, frame_count)
end

return SampleWriter
