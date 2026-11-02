-- Instrument layout of the Renoise song: the instruments are grouped by track, each group starts with an empty
-- separator instrument ("---- AHX 1 ----"), and the instruments of a track follow in the order of their first use.
-- Every track plays its own instances: the volume and filter macros belong to the instrument, so an instrument played
-- on several tracks needs one instance per track (the first one is built, the others are copies). Instruments the
-- song never plays come last, in a group "unused".

local InstrumentSlots = {}

-- Renoise allows at most 255 instruments.
local MAX_INSTRUMENTS = 255

---@class AhxInstrumentSlot
---@field index integer Renoise instrument index
---@field separator string|nil name of an empty separator instrument
---@field source integer|nil AHX instrument number
---@field copy_of integer|nil Renoise index of the instance to copy (nil: build this instance)
---@field channel integer|nil track that plays the instance (nil for unused instruments)

---@param song AhxSong
---@param channel_instruments integer[][] AHX instruments per channel in the order of their first use
---@return table<integer, table<integer, integer>> slots Renoise instrument index per channel and AHX instrument
---@return AhxInstrumentSlot[] layout all Renoise instruments in index order
function InstrumentSlots.plan(song, channel_instruments)
  local slots = { {}, {}, {}, {} }
  local layout = {}
  local built = {}

  local function add(slot)
    slot.index = #layout + 1
    layout[slot.index] = slot
    return slot.index
  end
  local function add_instance(instrument, channel)
    local index = add({ source = instrument, copy_of = built[instrument], channel = channel })
    built[instrument] = built[instrument] or index
    return index
  end

  for channel = 1, 4 do
    local instruments = channel_instruments[channel] or {}
    if #instruments > 0 then
      add({ separator = ('---- AHX %d ----'):format(channel) })
      for _, instrument in ipairs(instruments) do
        slots[channel][instrument] = add_instance(instrument, channel)
      end
    end
  end

  local unused = {}
  for instrument = 1, song.instrument_count do
    if not built[instrument] then
      unused[#unused + 1] = instrument
    end
  end
  if #unused > 0 then
    add({ separator = '---- unused ----' })
    for _, instrument in ipairs(unused) do
      add_instance(instrument, nil)
    end
  end

  if #layout > MAX_INSTRUMENTS then
    error(
      ('The song needs %d instruments (one instance per track plus separators), Renoise allows %d.'):format(
        #layout,
        MAX_INSTRUMENTS
      ),
      0
    )
  end
  return slots, layout
end

return InstrumentSlots
