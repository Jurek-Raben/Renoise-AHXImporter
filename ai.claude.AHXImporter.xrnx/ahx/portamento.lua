-- Track portamento of the AHX replayer (commands 1xx, 2xx, 3xx, 5xx, E1x, E2x; `PeriodSlide*` of `ProcessStep` and
-- `ProcessFrame`). The slide period is added to the period of the playing note.
--
-- Renoise plays AHX instruments with phrases that switch samples during a note (PWM, waveforms) and keep the phase
-- with sample offsets computed from the pitch. A pattern slide (0U/0D/0G) changes the pitch behind the phrase's back,
-- so every sample switch lands at the wrong phase (stuttering slide, mobby - good day, AHX 1 / instrument 02). The
-- slide periods are therefore baked into variant phrases: one per distinct slide after a trigger (see `NoteUsage`).

local bit = require('bit')

local Tables = require('ahx.tables')

local Portamento = {}

---@class AhxPortamento
---@field speed integer `PeriodSlideSpeed`
---@field period integer `PeriodSlidePeriod`, added to the period of the note
---@field limit integer `PeriodSlideLimit` (tone portamento target)
---@field on boolean `PeriodSlideOn`
---@field with_limit boolean `PeriodSlideWithLimit`
---@field track_note integer `TrackPeriod`: track note 0..60 without position transpose

---@return AhxPortamento
function Portamento.new()
  return { speed = 0, period = 0, limit = 0, on = false, with_limit = false, track_note = 0 }
end

---Applies the portamento part of `ProcessStep` for one step, in the replayer's order: instrument reset, tone
---portamento, note, slides, fine slides. Returns false when the step's note does not trigger (tone portamento).
---@param portamento AhxPortamento
---@param step AhxStep
---@return boolean note_triggers
function Portamento.process_step(portamento, step)
  local fx, param, note = step.fx, step.fx_param, step.note
  if step.instrument > 0 then
    portamento.speed, portamento.period, portamento.limit = 0, 0, 0
  end
  portamento.on = false

  local note_triggers = note > 0
  if fx == 0x3 or fx == 0x5 then
    if param ~= 0 then
      portamento.speed = param
    end
    if note > 0 then
      local new = Tables.PERIODS[note]
      local old = Tables.PERIODS[portamento.track_note] - new
      if old + portamento.period ~= 0 then
        portamento.limit = -old
      end
    end
    portamento.on = true
    portamento.with_limit = true
    note_triggers = false
  end

  if note_triggers then
    portamento.track_note = note
  end

  if fx == 0x1 then
    portamento.speed = -param
    portamento.on = true
    portamento.with_limit = false
  elseif fx == 0x2 then
    portamento.speed = param
    portamento.on = true
    portamento.with_limit = false
  elseif fx == 0xe then
    local high, low = bit.rshift(param, 4), bit.band(param, 0x0f)
    if high == 0x1 then
      portamento.period = -low
    elseif high == 0x2 then
      portamento.period = low
    end
  end
  return note_triggers
end

---Applies the portamento part of `ProcessFrame` (once per frame, also in the frame of the step).
---@param portamento AhxPortamento
function Portamento.process_frame(portamento)
  if not portamento.on then
    return
  end
  if portamento.with_limit then
    local distance = portamento.period - portamento.limit
    local speed = portamento.speed
    if distance > 0 then
      speed = -speed
    end
    if distance ~= 0 then
      -- The replayer checks the sign of `(distance + speed) ^ distance`: overshooting the limit stops at the limit.
      if bit.bxor(distance + speed, distance) >= 0 then
        portamento.period = portamento.period + speed
      else
        portamento.period = portamento.limit
      end
    end
  else
    portamento.period = portamento.period + portamento.speed
  end
end

return Portamento
