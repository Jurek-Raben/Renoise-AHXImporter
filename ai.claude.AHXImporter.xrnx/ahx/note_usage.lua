-- Finds the Renoise notes (track note + position transpose) each AHX instrument is triggered with, from the triggers
-- the pattern converter records in play order (`PatternConverter.scan_triggers`). Every such note gets its own phrase,
-- so the phrase can play exact absolute pitches and phase-continuous sample switches.
-- A trigger that starts differently gets an extra (unmapped) variant phrase that the pattern selects with 0Zxx:
--   * a square offset (track command 9xx) starts the instrument with another square position,
--   * a pitch slide after the trigger (1xx, 2xx, 3xx, 5xx, E1x, E2x) is baked into the phrase (see `Portamento`).

local NoteUsage = {}

-- AHX note n is Renoise note n + 11 (AHX C-1 = Renoise C-1 = 12).
NoteUsage.NOTE_OFFSET = 11

-- Used for instruments the song never triggers (still playable from the keyboard there).
NoteUsage.DEFAULT_NOTE = 36

-- Renoise notes of the AHX notes 1..60. Outside of them the period table clamps, so more keys would not sound higher.
NoteUsage.FIRST_NOTE = NoteUsage.NOTE_OFFSET + 1
NoteUsage.LAST_NOTE = NoteUsage.NOTE_OFFSET + 60

---@class AhxNoteVariant
---@field key string identifies the variant (`NoteUsage.variant_key`)
---@field note integer Renoise note
---@field square_offset integer|nil 9xx parameter
---@field slides integer[]|nil slide period per frame from the trigger on (the last value holds)
---@field uses integer number of triggers that play it

---@class AhxInstrumentUsage
---@field notes integer[] sorted notes of plain triggers (never empty)
---@field variants AhxNoteVariant[] most used first
---@field square_offsets integer[] sorted distinct 9xx parameters
---@field center_note integer weighted median of all triggered notes, inside the AHX note range (start of the fill up)

---The note in the middle of all triggers (a single far away note does not move it, unlike the middle of the range).
---@param counts table<integer, integer> number of triggers by note
---@return integer center inside FIRST_NOTE..LAST_NOTE; DEFAULT_NOTE without triggers
local function weighted_median(counts)
  local notes, total = {}, 0
  for note, count in pairs(counts) do
    notes[#notes + 1] = note
    total = total + count
  end
  table.sort(notes)
  local center, sum = NoteUsage.DEFAULT_NOTE, 0
  for _, note in ipairs(notes) do
    sum = sum + counts[note]
    if sum * 2 >= total then
      center = note
      break
    end
  end
  return math.max(NoteUsage.FIRST_NOTE, math.min(NoteUsage.LAST_NOTE, center))
end

---All notes of the AHX note range by their distance to the center note, alternating above and below.
---@param center_note integer
---@return integer[]
function NoteUsage.fill_order(center_note)
  local order = { center_note }
  for distance = 1, NoteUsage.LAST_NOTE - NoteUsage.FIRST_NOTE do
    if center_note + distance <= NoteUsage.LAST_NOTE then
      order[#order + 1] = center_note + distance
    end
    if center_note - distance >= NoteUsage.FIRST_NOTE then
      order[#order + 1] = center_note - distance
    end
  end
  return order
end

---The slide periods without the trailing repeats of the last value; nil when there is no slide at all.
---@param slides integer[]
---@return integer[]|nil
local function trimmed_slides(slides)
  local last = #slides
  while last > 1 and slides[last] == slides[last - 1] do
    last = last - 1
  end
  local result = {}
  local any = false
  for index = 1, last do
    result[index] = slides[index]
    any = any or slides[index] ~= 0
  end
  return any and result or nil
end

---@param note integer
---@param square_offset integer|nil
---@param slides integer[]|nil
---@return string
function NoteUsage.variant_key(note, square_offset, slides)
  return ('%s:%d:%s'):format(square_offset or '-', note, slides and table.concat(slides, ',') or '')
end

---@param song AhxSong
---@param triggers AhxTrigger[]
---@return table<integer, AhxInstrumentUsage> usage by AHX instrument number
---@return table<string, string> variant key by trigger id (plain triggers are missing)
function NoteUsage.from_triggers(song, triggers)
  local plain, variants, trigger_keys, note_counts = {}, {}, {}, {}
  for _, trigger in ipairs(triggers) do
    local instrument = trigger.instrument
    note_counts[instrument] = note_counts[instrument] or {}
    note_counts[instrument][trigger.note] = (note_counts[instrument][trigger.note] or 0) + 1
    local slides = trimmed_slides(trigger.slides)
    if trigger.square_offset or slides then
      local key = NoteUsage.variant_key(trigger.note, trigger.square_offset, slides)
      variants[instrument] = variants[instrument] or {}
      local variant = variants[instrument][key]
      if not variant then
        variant = { key = key, note = trigger.note, square_offset = trigger.square_offset, slides = slides, uses = 0 }
        variants[instrument][key] = variant
      end
      variant.uses = variant.uses + 1
      trigger_keys[trigger.id] = key
    else
      plain[instrument] = plain[instrument] or {}
      plain[instrument][trigger.note] = true
    end
  end

  local result = {}
  for number = 1, song.instrument_count do
    local usage = {
      notes = {},
      variants = {},
      square_offsets = {},
      center_note = weighted_median(note_counts[number] or {}),
    }
    for note in pairs(plain[number] or {}) do
      usage.notes[#usage.notes + 1] = note
    end
    table.sort(usage.notes)
    if #usage.notes == 0 then
      usage.notes[1] = NoteUsage.DEFAULT_NOTE
    end

    -- Most used variants first: they keep their phrases when the phrase limit is reached.
    local offsets = {}
    for _, variant in pairs(variants[number] or {}) do
      usage.variants[#usage.variants + 1] = variant
      if variant.square_offset then
        offsets[variant.square_offset] = true
      end
    end
    table.sort(usage.variants, function(a, b)
      if a.uses ~= b.uses then
        return a.uses > b.uses
      end
      return a.key < b.key
    end)
    for offset in pairs(offsets) do
      usage.square_offsets[#usage.square_offsets + 1] = offset
    end
    table.sort(usage.square_offsets)

    result[number] = usage
  end
  return result, trigger_keys
end

return NoteUsage
