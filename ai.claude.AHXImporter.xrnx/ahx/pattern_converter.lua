-- Converts AHX track steps of a segment into neutral pattern data (no Renoise API), keeping per-channel state
-- (current note, instrument, volume, glide speed) and the tempo across segments.
--
-- Output cell values are Renoise values: note 0..119, instrument 0-based, volume 0..0x80, delay 0..255,
-- effects as { number = 'ZT', amount = 0..255 }.

local bit = require('bit')

local Resolution = require('ahx.resolution')
local Tables = require('ahx.tables')
local Timing = require('ahx.timing')

local PatternConverter = {}
PatternConverter.__index = PatternConverter

-- AHX note n is Renoise note n + 11 (AHX C-1 = Renoise C-1 = 12).
local NOTE_OFFSET = 11
local FULL_VOLUME = 0x40

---@class AhxCell
---@field note integer|nil
---@field note_off boolean|nil
---@field delay_frames integer|nil frames after the row start (note delay, note cut, hard cut); placed by `convert`
---@field vibrato { amount: integer, first_sub: integer }|nil 0Vxy from sub line `first_sub` on; placed by `convert`
---@field instrument integer|nil
---@field volume integer|nil
---@field delay integer|nil
---@field effects { number: string, amount: integer }[]

---@class AhxPatternData
---@field segment AhxSegment
---@field number_of_lines integer
---@field channels table<integer, table<integer, AhxCell>> channels[1..4][line 1..n], only non-empty cells
---@field effect_columns integer highest number of effects in one cell
---@field uses_delay boolean
---@field key string content fingerprint for de-duplication

---@param song AhxSong
---@param plan AhxTimingPlan
---@param report fun(name: string) collects commands that are not converted (yet)
---@param variant_phrases table<integer, table<string, integer>> 9xx phrase index by instrument and offset:note
---@param lines_per_row integer|nil pattern lines per AHX row (pattern resolution option, default 1)
---@return table converter
function PatternConverter.new(song, plan, report, variant_phrases, lines_per_row)
  local self = setmetatable({}, PatternConverter)
  self.song = song
  self.plan = plan
  self.variant_phrases = variant_phrases or {}
  self.lines_per_row = lines_per_row or 1
  self.report_unsupported = function(_, name)
    report(name)
  end
  self.tempo = Timing.INITIAL_SPEED
  self.channels = {}
  for channel = 1, 4 do
    self.channels[channel] = {
      note = nil,
      instrument = 0,
      volume = FULL_VOLUME,
      channel_volume = nil,
      glide = 0,
      vibrato = nil,
      frames = 0,
      track_master_volume = FULL_VOLUME,
      heard_volume = FULL_VOLUME,
      triggered = false,
      cut = false,
      hard_cut = 0,
    }
  end
  return self
end

-- Renoise slide units per semitone and tick. Verified by ear in Renoise (syphus - better days): xx/16 was half as
-- fast as the AHX original, so 0Uxx / 0Dxx / 0Gxx slide by xx/32 semitones per tick.
local SLIDE_UNITS_PER_SEMITONE = 32
-- The glide (0Gxx, from 3xx/5xx) is scaled differently: verified by ear, it needs xx/64 semitones per tick
-- (syphus - better days, AHX 2, pattern 2, line 15: G10 instead of G08).
local GLIDE_UNITS_PER_SEMITONE = 64

-- Instrument vibrato as pattern vibrato 0Vxy on every row once the vibrato delay has run out (an LFO in the
-- instrument restarts with every sample switch of the phrase).
-- Speed: AHX advances a 64-step sine by `speed` per frame, i.e. the vibrato rate is fixed in Hz. Renoise's 0Vxy rate
-- follows the lines (rate ∝ x · lines per second), so x = speed · song speed / (6 · lines per row) (verified by ear:
-- xeron - 64k is all you need at speed 3 / 1×, pink - thanatos remix at speed 16 / 2×). x is at most F, so slow
-- songs need a higher pattern resolution (see `Resolution`).
-- Depth: AHX adds `sine · depth >> 7` to the period, so the depth in semitones depends on the note (high notes have
-- small periods). It is converted per row at the current note; Renoise depth is semitone-based.
-- y = depth in 1/8 semitones (verified by ear: xeron - 64k is all you need, syphus - better days).
local VIBRATO_DEPTH_UNITS_PER_SEMITONE = 8

---Renoise slide amount (per tick = per AHX frame) for an AHX period slide at a note.
---@param period_step integer period change per frame
---@param note integer|nil Renoise note the slide starts from
---@param units_per_semitone integer
---@return integer
local function slide_amount(period_step, note, units_per_semitone)
  if period_step == 0 then
    return 0
  end
  local ahx_note = math.max(1, math.min(60, (note or 36) - NOTE_OFFSET))
  local period = Tables.PERIODS[ahx_note]
  local target = math.max(1, period - period_step)
  local semitones = math.abs(12 * math.log(period / target) / math.log(2))
  return math.max(1, math.min(255, math.floor(semitones * units_per_semitone + 0.5)))
end

---Peak vibrato deviation in semitones for an AHX vibrato depth at a note (average of up and down).
---@param depth integer 0..15
---@param note integer|nil Renoise note
---@return number
local function vibrato_semitones(depth, note)
  local ahx_note = math.max(1, math.min(60, (note or 36) - NOTE_OFFSET))
  local period = Tables.PERIODS[ahx_note]
  local offset = bit.arshift(255 * depth, 7)
  local up = math.log(period / math.max(1, period - offset))
  local down = math.log((period + offset) / period)
  return 12 * (up + down) / 2 / math.log(2)
end

---@param cell AhxCell
---@param number string
---@param amount integer
local function add_effect(cell, number, amount)
  cell.effects[#cell.effects + 1] = { number = number, amount = amount }
end

---Writes the Z commands for a speed change (the BPM stays constant, see `Timing`).
---@param cell AhxCell
---@param tempo integer
function PatternConverter:add_tempo(cell, tempo)
  local lpb, tpl, exact = Timing.for_speed(self.plan, tempo, self.lines_per_row)
  if not exact then
    self:report_unsupported(('speed %d (approximated)'):format(tempo))
  end
  add_effect(cell, 'ZL', lpb)
  add_effect(cell, 'ZK', tpl)
end

---Converts one step of one channel.
---@param channel integer 1..4
---@param step AhxStep
---@param transpose integer position transpose of the channel
---@param next_instrument integer instrument of the channel's next step (as the replayer's hard cut looks ahead)
---@return AhxCell
function PatternConverter:convert_step(channel, step, transpose, next_instrument)
  local state = self.channels[channel]
  local cell = { effects = {} }
  local fx = step.fx
  local param = step.fx_param
  local low = bit.band(param, 0x0f)
  local high = bit.rshift(param, 4)

  local note = nil
  if step.note > 0 then
    note = math.max(0, math.min(119, step.note + transpose + NOTE_OFFSET))
  end

  -- The row's speed is already set by `convert` (the replayer runs all steps of a row before its frames).
  if fx == 0xf and param > 0 then
    self:add_tempo(cell, param)
  end

  -- Note delay
  if fx == 0xe and high == 0xd and low > 0 and low < self.tempo then
    cell.delay_frames = low
  end

  local instrument = step.instrument
  if instrument > 0 then
    state.instrument = instrument
    local triggered_instrument = self.song.instruments[instrument]
    state.hard_cut = triggered_instrument and triggered_instrument.hard_cut_release_frames or 0
    state.volume = self.song.instruments[instrument] and self.song.instruments[instrument].volume or 0
    cell.instrument = instrument - 1
  end

  local tone_portamento = fx == 0x3 or fx == 0x5
  if tone_portamento then
    if param ~= 0 and fx == 0x3 then
      state.glide = slide_amount(param, state.note or note, GLIDE_UNITS_PER_SEMITONE)
    end
    if note then
      cell.note = note
      state.note = note
    end
    add_effect(cell, '0G', state.glide)
  elseif note then
    cell.note = note
    if instrument == 0 and state.note and state.instrument > 0 then
      -- AHX changes the pitch without retriggering the instrument.
      -- ASSUMPTION: 0GFF glides instantly, i.e. changes the pitch without a retrigger.
      add_effect(cell, '0G', 0xff)
    end
    state.note = note
  elseif instrument > 0 then
    -- Instrument without note: AHX retriggers the instrument at the current pitch.
    cell.note = state.note
  end

  if cell.instrument and not cell.note then
    -- Nothing to retrigger yet.
    cell.instrument = nil
  end

  if fx == 0x1 then
    add_effect(cell, '0U', slide_amount(param, state.note, SLIDE_UNITS_PER_SEMITONE))
  elseif fx == 0x2 then
    add_effect(cell, '0D', slide_amount(param, state.note, SLIDE_UNITS_PER_SEMITONE))
  elseif fx == 0xc then
    if param <= 0x40 then
      state.volume = param
    elseif param - 0x50 <= 0x40 then
      -- C50..C90: master volume of all voices (applied after the row, see `apply_channel_volumes`).
      self.new_master_volume = math.max(0, param - 0x50)
    elseif param - 0xa0 >= 0 and param - 0xa0 <= 0x40 then
      -- CA0..CE0: master volume of this voice.
      state.track_master_volume = param - 0xa0
    end
  elseif fx == 0xe then
    if high == 0xa then
      state.volume = math.min(FULL_VOLUME, state.volume + low)
    elseif high == 0xb then
      state.volume = math.max(0, state.volume - low)
    elseif high == 0xc then
      if low > 0 and low < self.tempo then
        -- Note cut after `low` frames. The phrase rewrites the note volume on its lines, so a volume cut (0Cxy) does
        -- not last; a delayed note-off stops the phrase instead. With a note on the same row only 0Cxy is possible.
        if cell.note then
          add_effect(cell, '0C', low)
        else
          cell.note_off = true
          cell.delay_frames = low
        end
        state.cut = true
        state.hard_cut = 0
      end
    elseif high == 0x1 or high == 0x2 then
      self:report_unsupported('E1x/E2x fine slide')
    elseif high == 0x4 then
      state.new_vibrato_depth = low
    end
  elseif fx == 0x9 then
    -- The square offset changes how the instrument starts: its variant phrase is selected with 0Zxx.
    -- 0Zxx plays phrase xx of the instrument for this note, also in keymap mode (verified by ear).
    local variants = self.variant_phrases[state.instrument]
    local index = cell.instrument and cell.note and variants and variants[param .. ':' .. cell.note]
    if index then
      add_effect(cell, '0Z', index)
    else
      self:report_unsupported('9xx without trigger or beyond the phrase limit')
    end
  elseif fx == 0x4 then
    self:report_unsupported('4xx filter override')
  end

  -- Note volume (AHX `NoteMaxVolume`). The phrase writes the envelope into every note line's volume, which would
  -- overwrite volume column values and fades of the pattern, so the note volume goes into the channel volume (0Mxx)
  -- instead: on every trigger, and whenever it changes. Volume slides (A, 5) run per frame; the channel volume is
  -- set per row to the value after the row's first frame.
  -- Hard cut: an instrument with hard cut frames ends its note that many frames before the next row that triggers an
  -- instrument (with release when the instrument says so, see `ReleaseWriter`). A delayed note-off does it; on a row
  -- with its own note there is no room for one.
  if state.hard_cut > 0 and next_instrument > 0 then
    if not cell.note and not cell.note_off and not cell.delay_frames then
      cell.note_off = true
      cell.delay_frames = math.max(0, self.tempo - state.hard_cut)
    end
    state.hard_cut = 0
  end

  -- The channel volume itself is written after the whole row (`apply_channel_volumes`), because a master volume
  -- command in one channel changes all channels.
  state.heard_volume = state.volume
  if fx == 0x5 or fx == 0xa then
    local delta = high - low
    state.heard_volume = math.max(0, math.min(FULL_VOLUME, state.volume + delta))
    state.volume = math.max(0, math.min(FULL_VOLUME, state.volume + delta * self.tempo))
  end
  state.triggered = cell.instrument ~= nil
  if state.cut then
    -- The cut note stays silent until the next trigger (the replayer sets the note volume to 0).
    state.cut = false
    state.volume = 0
  end

  self:add_vibrato(cell, state)

  return cell
end

---Writes 0Vxy on rows where the instrument vibrato is running (after its delay, until the next trigger).
---@param cell AhxCell
---@param state table channel state
function PatternConverter:add_vibrato(cell, state)
  if cell.instrument then
    local instrument = self.song.instruments[cell.instrument + 1]
    state.vibrato = {
      depth = instrument.vibrato_depth,
      speed = instrument.vibrato_speed,
      delay = instrument.vibrato_delay,
    }
    state.frames = 0
  end
  -- E4x changes the depth after the instrument trigger of the same row.
  if state.new_vibrato_depth then
    if state.vibrato then
      state.vibrato.depth = state.new_vibrato_depth
    end
    state.new_vibrato_depth = nil
  end

  local vibrato = state.vibrato
  -- The replayer starts the vibrato in the first frame after `delay` frames. A row spans `lines_per_row` lines; the
  -- vibrato starts on the first line whose middle lies behind the delay (a whole row at once started it too early with
  -- a long delay and slow speed: pink - thanatos remix, speed 16, delay 8).
  local frames_per_line = self.tempo / self.lines_per_row
  local first_sub = nil
  if vibrato then
    for sub = 0, self.lines_per_row - 1 do
      if state.frames + (sub + 0.5) * frames_per_line > vibrato.delay then
        first_sub = sub
        break
      end
    end
  end
  if vibrato and vibrato.depth > 0 and vibrato.speed > 0 and first_sub then
    local speed = Resolution.vibrato_speed(vibrato.speed, self.tempo, self.lines_per_row)
    local depth = math.floor(vibrato_semitones(vibrato.depth, state.note) * VIBRATO_DEPTH_UNITS_PER_SEMITONE + 0.5)
    if speed > 15 or depth > 15 then
      self:report_unsupported('vibrato speed/depth above F (clamped)')
    end
    -- Depth 0: the vibrato is too small to hear at this pitch (and 0V with y = 0 may continue the previous depth).
    if depth > 0 then
      cell.vibrato = { amount = math.min(15, math.max(1, speed)) * 16 + math.min(15, depth), first_sub = first_sub }
    end
  end
  state.frames = state.frames + self.tempo
end

---@param cell AhxCell
---@return boolean
local function is_empty(cell)
  return cell.note == nil
    and not cell.note_off
    and cell.instrument == nil
    and cell.volume == nil
    and cell.delay == nil
    and cell.delay_frames == nil
    and #cell.effects == 0
end

---@param cell AhxCell
---@return string
local function cell_key(cell)
  local note = cell.note or (cell.note_off and 'OFF') or ''
  local parts = { note, cell.instrument or '', cell.volume or '', cell.delay or '' }
  for _, effect in ipairs(cell.effects) do
    parts[#parts + 1] = effect.number .. effect.amount
  end
  return table.concat(parts, ',')
end

---Writes the channel volume (0Mxx) of all channels of a row: note volume (AHX `NoteMaxVolume`) times the voice's
---master volume (`TrackMasterVolume`, C50..C90 for all voices, CA0..CE0 per voice). The phrase writes the envelope
---into every note line's volume, which would overwrite volume column values and fades of the pattern, so the note
---volume goes into the channel volume instead: on every trigger, and whenever it changes. Volume slides (A, 5) run
---per frame; the channel volume is set per row to the value after the row's first frame.
---@param cells AhxCell[] the row's cells of channels 1..4
function PatternConverter:apply_channel_volumes(cells)
  if self.new_master_volume then
    for channel = 1, 4 do
      self.channels[channel].track_master_volume = self.new_master_volume
    end
    self.new_master_volume = nil
  end

  for channel = 1, 4 do
    local state = self.channels[channel]
    local volume = state.heard_volume * state.track_master_volume / FULL_VOLUME
    -- 0Mxx sets the channel volume to xx / 0xFF (fades verified by ear: xeron - 64k is all you need).
    local amount = math.floor(volume * 0xff / FULL_VOLUME + 0.5)
    if state.triggered or amount ~= state.channel_volume then
      add_effect(cells[channel], '0M', amount)
      state.channel_volume = amount
    end
  end
end

---Merges a cell into the line of a channel (keeps existing values, appends effects).
---@param lines table<integer, AhxCell>
---@param line integer
---@param cell AhxCell
local function merge(lines, line, cell)
  local existing = lines[line]
  if not existing then
    lines[line] = cell
    return
  end
  for _, field in ipairs({ 'note', 'note_off', 'instrument', 'volume', 'delay' }) do
    if existing[field] == nil then
      existing[field] = cell[field]
    end
  end
  for _, effect in ipairs(cell.effects) do
    existing.effects[#existing.effects + 1] = effect
  end
end

---Places the cell of one row on its pattern lines. A row spans `lines_per_row` lines: delayed events (note delay,
---note cut, hard cut) go to the sub line of their frame with the remaining fraction in the delay column, and the
---vibrato command is repeated on every line of the row.
---@param lines table<integer, AhxCell>
---@param line integer first line of the row
---@param cell AhxCell
function PatternConverter:place(lines, line, cell)
  local per_row = self.lines_per_row
  local frames = cell.delay_frames
  cell.delay_frames = nil

  if frames then
    local position = frames * per_row / self.tempo
    local sub = math.floor(position)
    local delay = math.min(255, math.floor((position - sub) * 256))
    if cell.note_off then
      -- The note-off gets a cell of its own on its sub line; the row's effects stay on the first line.
      cell.note_off = nil
      if sub == 0 then
        cell.note_off = true
        cell.delay = delay
      else
        merge(lines, line + sub, { note_off = true, delay = delay, effects = {} })
      end
    elseif sub == 0 then
      cell.delay = delay
    else
      -- Note delay: the whole step moves (the replayer processes the step only after the delay).
      cell.delay = delay
      merge(lines, line + sub, cell)
      cell = { effects = {} }
    end
  end

  local vibrato = cell.vibrato
  cell.vibrato = nil
  if vibrato then
    for sub = vibrato.first_sub, per_row - 1 do
      if sub == 0 then
        add_effect(cell, '0V', vibrato.amount)
      else
        merge(lines, line + sub, { effects = { { number = '0V', amount = vibrato.amount } } })
      end
    end
  end

  if not is_empty(cell) then
    merge(lines, line, cell)
  end
end

---Converts one segment into pattern data.
---@param segment AhxSegment
---@return AhxPatternData
function PatternConverter:convert(segment)
  local song = self.song
  local position = song.positions[segment.position]
  local data = {
    segment = segment,
    number_of_lines = (segment.last_row - segment.first_row + 1) * self.lines_per_row,
    channels = { {}, {}, {}, {} },
    effect_columns = 0,
    uses_delay = false,
  }
  local key_parts = { data.number_of_lines }
  -- The replayer's look-ahead (hard cut) uses the next position of the list, regardless of jumps.
  local next_position = song.positions[(segment.position + 1) % song.position_count]

  for row = segment.first_row, segment.last_row do
    local line = (row - segment.first_row) * self.lines_per_row + 1
    -- The replayer processes the steps of all four voices before the frames of the row, so a speed command in any
    -- channel already applies to the frame timing (note delay, note cut, hard cut, slides) of all channels of this
    -- row (mobby - good day: swing via F05/F0A on AHX 2, hard cut bass on AHX 1).
    for channel = 1, 4 do
      local step = song.tracks[position.track[channel - 1]][row]
      if step.fx == 0xf and step.fx_param > 0 then
        self.tempo = step.fx_param
      end
    end

    local cells = {}
    for channel = 1, 4 do
      local steps = song.tracks[position.track[channel - 1]]
      local next_step
      if row + 1 < song.track_length then
        next_step = steps[row + 1]
      else
        next_step = song.tracks[next_position.track[channel - 1]][0]
      end
      cells[channel] = self:convert_step(channel, steps[row], position.transpose[channel - 1], next_step.instrument)
    end
    self:apply_channel_volumes(cells)

    for channel = 1, 4 do
      self:place(data.channels[channel], line, cells[channel])
    end
  end

  for channel = 1, 4 do
    for line = 1, data.number_of_lines do
      local cell = data.channels[channel][line]
      if cell then
        data.effect_columns = math.max(data.effect_columns, #cell.effects)
        data.uses_delay = data.uses_delay or cell.delay ~= nil
        key_parts[#key_parts + 1] = ('%d:%d=%s'):format(line, channel, cell_key(cell))
      end
    end
  end

  data.key = table.concat(key_parts, ';')
  return data
end

return PatternConverter
