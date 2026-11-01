-- Finds the Renoise notes (track note + position transpose) each AHX instrument is triggered with. Every such note
-- gets its own phrase, so the phrase can play exact absolute pitches and phase-continuous sample switches.
-- Triggers with a square offset (track command 9xx) start the instrument differently; each used note/offset pair gets
-- an extra (unmapped) phrase that the pattern selects with 0Zxx.

local NoteUsage = {}

-- AHX note n is Renoise note n + 11 (AHX C-1 = Renoise C-1 = 12).
NoteUsage.NOTE_OFFSET = 11

-- Used for instruments the song never triggers (still playable from the keyboard there).
NoteUsage.DEFAULT_NOTE = 36

---@class AhxNoteVariant
---@field note integer Renoise note
---@field square_offset integer 9xx parameter

---@class AhxInstrumentUsage
---@field notes integer[] sorted notes of plain triggers (never empty)
---@field variants AhxNoteVariant[] sorted by square offset, then note
---@field square_offsets integer[] sorted distinct 9xx parameters

---Renoise note of a track note in a position channel.
---@param step AhxStep
---@param transpose integer
---@return integer
function NoteUsage.renoise_note(step, transpose)
  return math.max(0, math.min(119, step.note + transpose + NoteUsage.NOTE_OFFSET))
end

---@param song AhxSong
---@return table<integer, AhxInstrumentUsage> usage by AHX instrument number
function NoteUsage.scan(song)
  local plain, variants = {}, {}
  for position = 0, song.position_count - 1 do
    local entry = song.positions[position]
    for channel = 0, 3 do
      local steps = song.tracks[entry.track[channel]]
      for row = 0, song.track_length - 1 do
        local step = steps and steps[row]
        if step and step.instrument > 0 and step.note > 0 then
          local note = NoteUsage.renoise_note(step, entry.transpose[channel])
          if step.fx == 0x9 then
            variants[step.instrument] = variants[step.instrument] or {}
            variants[step.instrument][step.fx_param .. ':' .. note] = { note = note, square_offset = step.fx_param }
          else
            plain[step.instrument] = plain[step.instrument] or {}
            plain[step.instrument][note] = true
          end
        end
      end
    end
  end

  local result = {}
  for number = 1, song.instrument_count do
    local usage = { notes = {}, variants = {}, square_offsets = {} }
    for note in pairs(plain[number] or {}) do
      usage.notes[#usage.notes + 1] = note
    end
    table.sort(usage.notes)
    if #usage.notes == 0 then
      usage.notes[1] = NoteUsage.DEFAULT_NOTE
    end

    local offsets = {}
    for _, variant in pairs(variants[number] or {}) do
      usage.variants[#usage.variants + 1] = variant
      offsets[variant.square_offset] = true
    end
    table.sort(usage.variants, function(a, b)
      if a.square_offset ~= b.square_offset then
        return a.square_offset < b.square_offset
      end
      return a.note < b.note
    end)
    for offset in pairs(offsets) do
      usage.square_offsets[#usage.square_offsets + 1] = offset
    end
    table.sort(usage.square_offsets)

    result[number] = usage
  end
  return result
end

return NoteUsage
