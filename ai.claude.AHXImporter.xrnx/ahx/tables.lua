-- Constant tables of the AHX replayer. Indices are 0-based like in the original (index 0 of the period table is the
-- "no note" entry).

local Tables = {}

---@class AhxTuning
---@field name string
---@field clock number Paula clock in Hz (`clock / period` = playback rate of a period)
---@field sample_rate integer rate of a sample at its base note C-4 (= clock / 428, rounded; period 428 = C-4)
---@field tempered boolean notes sit exactly on the Renoise note instead of following the period table's tuning

-- ASSUMPTION: create_sample_data accepts these non-standard rates and their multiples (verified for 8363 Hz only).
-- Deviation from the reference replayer: it uses the NTSC clock (3579545.25 Hz); the default here is the PAL clock.
-- 440 Hz: A-4 = 440 Hz makes C-4 261.6256 Hz, and a 32-frame cycle plays at the note it is written at: 261.6256 * 32 =
-- 8372 Hz. The integer periods of the table are up to 4 cents off the tempered scale, so this tuning also ignores
-- their tuning (see `tempered`).
---@type AhxTuning[]
Tables.TUNINGS = {
  { name = 'Amiga PAL', clock = 3546895, sample_rate = 8287, tempered = false },
  { name = '440 Hz', clock = 8372 * 428, sample_rate = 8372, tempered = true },
}
Tables.DEFAULT_TUNING = 1

-- Length of the sample buffers written for waveform cycles (the cycle repeated). See `Waves.voice_buffer`.
Tables.SAMPLE_BUFFER_LENGTH = 256

local period_table = {
  0x0000, 0x0d60, 0x0ca0, 0x0be8, 0x0b40, 0x0a98, 0x0a00, 0x0970, 0x08e8, 0x0868, 0x07f0, 0x0780, 0x0714, 0x06b0,
  0x0650, 0x05f4, 0x05a0, 0x054c, 0x0500, 0x04b8, 0x0474, 0x0434, 0x03f8, 0x03c0, 0x038a, 0x0358, 0x0328, 0x02fa,
  0x02d0, 0x02a6, 0x0280, 0x025c, 0x023a, 0x021a, 0x01fc, 0x01e0, 0x01c5, 0x01ac, 0x0194, 0x017d, 0x0168, 0x0153,
  0x0140, 0x012e, 0x011d, 0x010d, 0x00fe, 0x00f0, 0x00e2, 0x00d6, 0x00ca, 0x00be, 0x00b4, 0x00aa, 0x00a0, 0x0097,
  0x008f, 0x0087, 0x007f, 0x0078, 0x0071,
}

local vibrato_table = {
  0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253, 255, 253, 250, 244, 235, 224, 212, 197,
  180, 161, 141, 120, 97, 74, 49, 24, 0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244,
  -250, -253, -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24,
}

---Converts a 1-based Lua array into a 0-based table.
---@param values integer[]
---@return table<integer, integer>
local function zero_based(values)
  local result = {}
  for i = 1, #values do
    result[i - 1] = values[i]
  end
  return result
end

-- Period per AHX note, 0-based: PERIODS[0] = 0 (no note), PERIODS[1] = C-1 … PERIODS[60] = B-5.
Tables.PERIODS = zero_based(period_table)

-- Vibrato sine, 0-based: VIBRATO[0..63].
Tables.VIBRATO = zero_based(vibrato_table)

return Tables
