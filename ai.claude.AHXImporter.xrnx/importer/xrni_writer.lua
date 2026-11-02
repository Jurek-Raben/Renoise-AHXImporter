-- Writes an empty Renoise instrument file (.xrni) whose macros are mapped to inputs of its modulation sets. The Lua
-- API can read macro mappings but not create them (`InstrumentMacro.mappings` is read-only), so the importer loads
-- such a file into the instrument slot (`renoise.app():load_instrument`) before it fills the instrument.
--
-- An .xrni is a ZIP archive with an `Instrument.xml`. The XML follows an instrument saved by Renoise 3.5.4
-- (doc_version 34) with a macro mapped by hand to the pitch input; the archive is written uncompressed ("stored").

local bit = require('bit')

local XrniWriter = {}

-- Modulation sets of the template that the importer has not used yet carry this name.
XrniWriter.UNUSED_SET_NAME = 'AHX unused'

-- Parameter indices of the inputs of a modulation set's mixer device (device 0). The example instrument maps the
-- pitch input as parameter 3; the others follow the order of the device's XML elements.
-- ASSUMPTION: 0 = active, 1 = volume, 2 = panning, 3 = pitch, 4 = cutoff, 5 = resonance, 6 = drive.
XrniWriter.VOLUME = 1
XrniWriter.PANNING = 2
XrniWriter.PITCH = 3
XrniWriter.CUTOFF = 4
XrniWriter.RESONANCE = 5
XrniWriter.DRIVE = 6

local crc_table = nil

---@param data string
---@return integer crc32 (may be negative, only its low 32 bits count)
local function crc32(data)
  if not crc_table then
    crc_table = {}
    for index = 0, 255 do
      local value = index
      for _ = 1, 8 do
        if bit.band(value, 1) == 1 then
          value = bit.bxor(bit.rshift(value, 1), 0xedb88320)
        else
          value = bit.rshift(value, 1)
        end
      end
      crc_table[index] = value
    end
  end
  local crc = 0xffffffff
  for index = 1, #data do
    crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, data:byte(index)), 0xff)])
  end
  return bit.bnot(crc)
end

---@param value integer
---@return string little-endian 16 bit
local function u16(value)
  return string.char(bit.band(value, 0xff), bit.band(bit.rshift(value, 8), 0xff))
end

---@param value integer
---@return string little-endian 32 bit
local function u32(value)
  return string.char(
    bit.band(value, 0xff),
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(bit.rshift(value, 16), 0xff),
    bit.band(bit.rshift(value, 24), 0xff)
  )
end

---ZIP archive with uncompressed entries.
---@param entries { name: string, data: string }[]
---@return string
local function zip(entries)
  -- 1980-01-01 00:00 in MS-DOS format.
  local dos_time, dos_date = 0, 0x21
  local parts, central = {}, {}
  local offset = 0
  for _, entry in ipairs(entries) do
    local crc = crc32(entry.data)
    local header = table.concat({
      u32(0x04034b50),
      u16(20),
      u16(0),
      u16(0),
      u16(dos_time),
      u16(dos_date),
      u32(crc),
      u32(#entry.data),
      u32(#entry.data),
      u16(#entry.name),
      u16(0),
      entry.name,
    })
    parts[#parts + 1] = header
    parts[#parts + 1] = entry.data
    central[#central + 1] = table.concat({
      u32(0x02014b50),
      u16(20),
      u16(20),
      u16(0),
      u16(0),
      u16(dos_time),
      u16(dos_date),
      u32(crc),
      u32(#entry.data),
      u32(#entry.data),
      u16(#entry.name),
      u16(0),
      u16(0),
      u16(0),
      u16(0),
      u32(0),
      u32(offset),
      entry.name,
    })
    offset = offset + #header + #entry.data
  end
  local directory = table.concat(central)
  parts[#parts + 1] = directory
  parts[#parts + 1] = table.concat({
    u32(0x06054b50),
    u16(0),
    u16(0),
    u16(#entries),
    u16(#entries),
    u32(#directory),
    u32(offset),
    u16(0),
  })
  return table.concat(parts)
end

---@param tag string
---@param name string
---@param value string
---@param mappings string|nil
---@return string
local function macro(tag, name, value, mappings)
  local mappings_block = mappings and ('\n      <Mappings>\n%s\n      </Mappings>'):format(mappings) or ''
  return ([[
    <%s>
      <Value>%s</Value>
      <Visualization>Device only</Visualization>
      <Name>%s</Name>%s
    </%s>]]):format(tag, value, name, mappings_block, tag)
end

---@param set_count integer
---@param parameter integer mixer device parameter index (XrniWriter.VOLUME, ...)
---@return string
local function mappings_xml(set_count, parameter)
  local parts = {}
  for index = 0, set_count - 1 do
    parts[#parts + 1] = ([[
        <Mapping>
          <DestChainType>ModulationSet</DestChainType>
          <DestChainIndex>%d</DestChainIndex>
          <DestDeviceIndex>0</DestDeviceIndex>
          <DestParameterIndex>%d</DestParameterIndex>
          <Min>0.0</Min>
          <Max>1.0</Max>
          <Scaling>Linear</Scaling>
        </Mapping>]]):format(index, parameter)
  end
  return table.concat(parts, '\n')
end

---@param pitch_range integer
---@return string
local function modulation_set_xml(pitch_range)
  return ([[
      <ModulationSet>
        <SelectedPresetName>Init</SelectedPresetName>
        <SelectedPresetLibrary>Bundled Content</SelectedPresetLibrary>
        <SelectedPresetIsModified>false</SelectedPresetIsModified>
        <Devices>
          <SampleMixerModulationDevice type="SampleMixerModulationDevice">
            <IsActive>
              <Value>1.0</Value>
              <Visualization>Device only</Visualization>
            </IsActive>
            <Volume>
              <Value>1.0</Value>
              <Visualization>Device only</Visualization>
            </Volume>
            <Panning>
              <Value>0.0</Value>
              <Visualization>Device only</Visualization>
            </Panning>
            <Pitch>
              <Value>0.0</Value>
              <Visualization>Device only</Visualization>
            </Pitch>
            <PitchModulationRange>%d</PitchModulationRange>
            <Cutoff>
              <Value>63.5</Value>
              <Visualization>Device only</Visualization>
            </Cutoff>
            <Resonance>
              <Value>63.5</Value>
              <Visualization>Device only</Visualization>
            </Resonance>
            <Drive>
              <Value>0.0</Value>
              <Visualization>Device only</Visualization>
            </Drive>
          </SampleMixerModulationDevice>
        </Devices>
        <Name>%s</Name>
        <FilterType>0</FilterType>
        <FilterBankVersion>3</FilterBankVersion>
      </ModulationSet>]]):format(pitch_range, XrniWriter.UNUSED_SET_NAME)
end

---@class AhxXrniMacro
---@field name string macro name shown in Renoise
---@field parameter integer mixer device parameter every modulation set maps the macro to (XrniWriter.VOLUME, ...)
---@field value number|nil initial value 0..1 (default 0.5)

---@class AhxXrniTemplate
---@field set_count integer empty modulation sets (named XrniWriter.UNUSED_SET_NAME)
---@field pitch_range integer|nil pitch range of the sets (default 12)
---@field macros table<integer, AhxXrniMacro> mapped macros by macro number 1..8

---Instrument XML of a template.
---@param template AhxXrniTemplate
---@return string
local function instrument_xml(template)
  local macros = {}
  for index = 1, 8 do
    local mapped = template.macros[index]
    if mapped then
      macros[index] = macro(
        'Macro' .. (index - 1),
        mapped.name,
        tostring((mapped.value or 0.5) * 100),
        mappings_xml(template.set_count, mapped.parameter)
      )
    else
      macros[index] = macro('Macro' .. (index - 1), 'Macro ' .. index, '50')
    end
  end
  local sets = {}
  for index = 1, template.set_count do
    sets[index] = modulation_set_xml(template.pitch_range or 12)
  end

  -- ASSUMPTION: Renoise fills in defaults for everything left out (samples, phrases, plugin and MIDI generator).
  return table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<RenoiseInstrument doc_version="34">',
    '  <Name>AHX</Name>',
    '  <GlobalProperties>',
    table.concat(macros, '\n'),
    macro('PitchbendMacro', 'Pitchbend', '50'),
    macro('ModulationWheelMacro', 'Modulation', '0.0'),
    macro('ChannelPressureMacro', 'Channel Pressure', '0.0'),
    '    <MacrosVisible>true</MacrosVisible>',
    '    <Volume>1.0</Volume>',
    '  </GlobalProperties>',
    '  <SampleGenerator>',
    '    <Samples>',
    '    </Samples>',
    '    <ModulationSets>',
    table.concat(sets, '\n'),
    '    </ModulationSets>',
    '  </SampleGenerator>',
    '</RenoiseInstrument>',
    '',
  }, '\n')
end

---Writes a template instrument to a temporary file.
---@param template AhxXrniTemplate
---@return string file_name
function XrniWriter.write(template)
  local file_name = os.tmpname('.xrni')
  local file = assert(io.open(file_name, 'wb'))
  file:write(zip({ { name = 'Instrument.xml', data = instrument_xml(template) } }))
  file:close()
  return file_name
end

---Loads a template into instrument slot `index` (it replaces the instrument) and returns the instrument of the slot.
---@param index integer 1-based instrument index
---@param template AhxXrniTemplate
---@return renoise.Instrument
function XrniWriter.load(index, template)
  local rns = renoise.song()
  local file_name = XrniWriter.write(template)
  rns.selected_instrument_index = index
  -- ASSUMPTION: load_instrument replaces the selected instrument completely and keeps the macro mappings of the file.
  local ok = renoise.app():load_instrument(file_name)
  os.remove(file_name)
  if not ok then
    error('loading the instrument template failed')
  end
  return rns.instruments[index]
end

return XrniWriter
