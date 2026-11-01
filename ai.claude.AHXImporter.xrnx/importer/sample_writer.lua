-- Writes AHX waveform buffers into Renoise samples.

local SampleWriter = {}

-- Rate at which a sample plays at its base note C-4. AHX note C-3 plays at 3579545.25 / 856 ≈ 4181.7 Hz (NTSC Paula),
-- AHX note n maps to Renoise note n + 11, so C-4 is one octave above: ≈ 8363.4 Hz.
-- create_sample_data accepts this non-standard rate (verified).
local SAMPLE_RATE = 8363
local BASE_NOTE = 48

---Fills a sample with a looped waveform buffer.
---@param sample renoise.Sample
---@param frames number[] signed 8-bit values
---@param name string
---@param options AhxImportOptions interpolation, bit depth and sample rate factor
function SampleWriter.write(sample, frames, name, options)
  local buffer = sample.sample_buffer
  -- A higher sample rate repeats every frame (sample and hold), so the waveform and the pitch stay the same, and 0Sxx
  -- (xx/256 of the length) still addresses the same frames of the original 256-frame buffer.
  local factor = options.sample_rate_factor
  local frame_count = #frames * factor

  if not buffer:create_sample_data(SAMPLE_RATE * factor, options.bit_depth, 1, frame_count) then
    error('Out of memory while creating sample "' .. name .. '"')
  end

  buffer:prepare_sample_data_changes(false)
  for i = 1, frame_count do
    buffer:set_sample_data(1, i, frames[math.floor((i - 1) / factor) + 1] / 128)
  end
  buffer:finalize_sample_data_changes()

  sample.name = name
  sample.interpolation_mode = options.interpolation
  sample.oversample_enabled = false
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

return SampleWriter
