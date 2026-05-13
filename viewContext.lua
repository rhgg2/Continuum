-- Pure throwaway snapshot built once per vm:rebuild; no callbacks, no
-- mutation, no migration — discard and rebuild on every change.

--invariant: pure: no side effects, no signals, no mutation of args
--invariant: identity row math: ppqToRow / rowToPPQ are inverses (modulo integer rounding) under uniform ppqPerRow
--shape: args = { length, numRows, rowPerBeat, ppqPerRow, timeSigs, temper }
local util   = require 'util'
local tuning = require 'tuning'

local args = ...

local length     = args.length
local numRows    = args.numRows
local rowPerBeat = args.rowPerBeat
local ppqPerRow  = args.ppqPerRow
local timeSigs   = args.timeSigs
local temper     = args.temper
local ctx        = {}

----- Temperament

function ctx:activeTemper() return temper end

function ctx:noteProjection(evt)
  if not (temper and evt and evt.pitch) then return end
  local detune    = evt.detune or 0
  local step, oct = tuning.midiToStep(temper, evt.pitch, detune)
  local label     = tuning.stepToText(temper, step, oct)
  local tm_, td_  = tuning.stepToMidi(temper, step, oct)
  local gap       = (evt.pitch * 100 + detune) - (tm_ * 100 + td_)

  local steps, n, period = temper.cents, #temper.cents, temper.period
  local left    = step == 1 and steps[n] - period or steps[step - 1]
  local right   = step == n and steps[1] + period or steps[step + 1]
  local halfGap = math.min(steps[step] - left, right - steps[step]) / 2

  return label, gap, halfGap
end

----- Timing

--contract: identity row math: column-event ppq is the logical position; rows are uniform ppqPerRow units. Inverse of rowToPPQ. The chan argument is unused at this layer (kept for the call-site signature).
function ctx:ppqToRow(ppqI, chan)
  if ppqI <= 0 then return 0 end
  if ppqI >= length then return numRows end
  return ppqI / ppqPerRow
end

--contract: identity row math: row × ppqPerRow, integer-rounded, clamped at length. On-grid iff ctx:rowToPPQ(round(ppqToRow(p)), chan) == p.
function ctx:rowToPPQ(row, chan)
  if row <= 0 then return 0 end
  if row >= numRows then return length end
  return math.floor(row * ppqPerRow + 0.5)
end

function ctx:snapRow(ppqI, chan) return util.round(self:ppqToRow(ppqI, chan)) end

function ctx:ppqPerRow() return ppqPerRow end

do -- exports ctx:rowBeatInfo, ctx:barBeatSub
  local function timeSigAt(ppq)
    local active = timeSigs[1]
    for i = 2, #timeSigs do
      if timeSigs[i].ppq <= ppq then active = timeSigs[i]
      else break end
    end
    return active
  end

  local function tsRow(ts) return math.floor(ctx:ppqToRow(ts.ppq)) end

  function ctx:rowBeatInfo(row)
    local ts = timeSigAt(self:rowToPPQ(row))
    if not ts then return false, false end
    local rel = row - tsRow(ts)
    return rel % (rowPerBeat * ts.num) == 0, rel % rowPerBeat == 0
  end

  function ctx:barBeatSub(row)
    local bar = 1
    for i, ts in ipairs(timeSigs) do
      local rpbar   = rowPerBeat * ts.num
      local next_   = timeSigs[i + 1]
      local nextRow = next_ and tsRow(next_) or math.huge
      if row < nextRow then
        local rel = row - tsRow(ts)
        return bar + rel // rpbar,
          (rel % rpbar) // rowPerBeat + 1,
          rel % rowPerBeat + 1,
          ts
      end
      bar = bar + (nextRow - tsRow(ts)) // rpbar
    end
    return bar, 1, 1, timeSigs[1]
  end
end

return ctx
