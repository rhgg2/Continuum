-- See docs/curveEditor.md for the model.
-- @noindex

--invariant: anchors never cross; t is clamped strictly between immediate neighbours before any onMove/onMoveFree fire
--invariant: editor owns no domain data; events/projections/eval/callbacks all supplied by host per frame
--invariant: transient state (hover, segHover, segPin, preview, previewSuppress, drag) lives in factory closure; segPin and drag straddle frames and are invalidated when host's dragId changes
--invariant: snapped move (no shift) constrains t to integer ticks; shift-held free move uses FREE_EPS_T margin against neighbours
--invariant: exactly one of {move-drag, hover, insert-preview, segHover} is active per frame; later branches are gated on earlier ones being absent
--shape: drag = { kind='move'|'tension'|'inert', id=dragId, idx=number, startMx, startMy, moved=bool, [startMouseT], [startTension, ax, ay, bx, by] }
--shape: segPin = { id=dragId, segI=number, mx=number, my=number }
--shape: preview = { t=number, val=number }
--shape: previewSuppress = { x=number, y=number }
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui   = require 'imgui' '0.10'
local painter = require 'painter'

local ctx, chrome, page = (...).ctx, (...).chrome, (...).page

local HIT_PX     = 6
local HIT_PX2    = HIT_PX * HIT_PX
local R_PASSIVE  = 2.5
local R_ACTIVE   = 4.5
local R_PREVIEW  = 3.5
local FREE_EPS_T = 1e-3   -- strict-between-neighbours margin in free (shift) mode

local hover, segHover, segPin, preview, previewSuppress, drag

local self = {}

--shape: FrameArgs = { rect={x0,yTop,w,h}, vMin, vMax, tMin, tMax, events, tOf=(evt)->t, evalCurve=(A,B,fracT)->val, snap=(t)->snappedT|nil, hovered=bool, dragId, colours=config-names{axis,envelope,anchor,anchorActive}, callbacks={onMove(idx,t,val), onMoveFree(idx,t,val), onInsert(t,val)->newIdx, onDelete(idx), onTension(idx,tau), onCycleShape(idx)} }
--contract: returns true iff the editor consumed the mouse this frame (host should suppress its own click handling)
--contract: callbacks fire synchronously during frame(); host must tolerate re-entrant reads of events on the same frame
--contract: host must call frame() inside the window whose drawlist the painter binds; gate a.hovered on its own IsWindowHovered
function self:frame(a)
  local rect      = a.rect
  local x0, yTop  = rect.x0, rect.yTop
  local w, hInner = rect.w,  rect.h
  local yBot      = yTop + hInner
  local valSpan   = math.max(1, hInner)
  local vMin,vMax = a.vMin, a.vMax
  local tMin,tMax = a.tMin, a.tMax
  local events    = a.events
  local n         = #events
  local tOf       = a.tOf
  local evalCurve = a.evalCurve
  local cb        = a.callbacks
  local cols      = a.colours
  local pt = painter.new(ctx, chrome, {
    ox = x0 - tMin * (w / (tMax - tMin)),
    oy = yBot + vMin * (valSpan / (vMax - vMin)),
    sx = w / (tMax - tMin),
    sy = -valSpan / (vMax - vMin),
  }, page)
  -- Single-axis projections off the one transform (x ignores v, y ignores t)
  -- so they can't drift from pt.toScreen / pt.fromScreen.
  local function tToX(tt) local x = pt.toScreen(tt, 0); return x end
  local function valToY(v) local _, y = pt.toScreen(0, v); return y end

  hover, segHover, preview = nil, nil, nil
  if segPin and segPin.id ~= a.dragId then segPin = nil end
  if drag   and drag.id   ~= a.dragId then drag   = nil end

  if vMin <= 0 and 0 <= vMax then
    pt.segment(tMin, 0, tMax, 0, cols.axis, 1)
  end

  -- the clip is the lane plus a 4px screen gutter; map that screen rect back
  -- through pt so edge anchors aren't shaved.
  local clip0x, clip0y = pt.fromScreen(x0 - 4, yTop - 4)
  local clip1x, clip1y = pt.fromScreen(x0 + w + 4, yBot + 4)
  pt.pushClip({ x0 = clip0x, y0 = clip0y, x1 = clip1x, y1 = clip1y })

  local tArr = {}
  for i = 1, n do tArr[i] = tOf(events[i]) end

  local segIdx = 1
  --contract: evalAtT mutates the enclosing segIdx; safe across forward and backward t sequences but not concurrent with itself
  local function evalAtT(t)
    if n == 0 then return 0 end
    while segIdx < n and tArr[segIdx + 1] <= t do segIdx = segIdx + 1 end
    while segIdx > 1 and tArr[segIdx]     >  t do segIdx = segIdx - 1 end
    local A, B = events[segIdx], events[segIdx + 1]
    if not B or t < tArr[segIdx] then return A.val or 0 end
    local tA, tB = tArr[segIdx], tArr[segIdx + 1]
    local frac   = tB > tA and (t - tA) / (tB - tA) or 0
    return evalCurve(A, B, frac) or A.val or 0
  end

  if n > 0 then
    local pts  = {}
    local span = math.max(1, math.ceil(w))   -- ~one sample per screen px
    for k = 0, span do
      local tt = tMin + (tMax - tMin) * k / span
      pts[#pts + 1] = tt
      pts[#pts + 1] = util.clamp(evalAtT(tt), vMin, vMax)
    end
    pt.polyline(pts, cols.envelope, 1.5)

    local ax, ay = {}, {}
    for i = 1, n do ax[i], ay[i] = pt.toScreen(tArr[i], events[i].val or 0) end

    if not drag then
      local mx, my = ImGui.GetMousePos(ctx)
      local best2 = HIT_PX2
      for i = 1, n do
        local dx, dy = mx - ax[i], my - ay[i]
        local d2 = dx*dx + dy*dy
        if d2 < best2 then best2, hover = d2, i end
      end
    end

    -- Active anchor: move-drag wins over hover. Tension drag deliberately
    -- does not promote — the segment polyline carries the active signal.
    local activeIdx = (drag and drag.kind == 'move' and drag.idx) or hover
    for i = 1, n do
      local r    = (i == activeIdx) and R_ACTIVE or R_PASSIVE
      local name = (i == activeIdx) and cols.anchorActive or cols.anchor
      pt.circle(tArr[i], events[i].val or 0, r, name)
    end
  end

  if not drag and not hover and a.hovered then
    local mx, my = ImGui.GetMousePos(ctx)
    local suppressed = previewSuppress
                       and math.abs(mx - previewSuppress.x) < 1
                       and math.abs(my - previewSuppress.y) < 1
    if not suppressed then
      previewSuppress = nil
      local mouseT = pt.fromScreen(mx, my)
      if mouseT >= tMin and mouseT < tMax then
        local snappedT = a.snap and a.snap(mouseT) or nil
        local nearLine = snappedT and math.abs(mx - tToX(snappedT)) <= HIT_PX

        if nearLine then
          local val = util.clamp(util.round(evalAtT(snappedT)), vMin, vMax)
          local py  = valToY(val)
          if math.abs(my - py) <= HIT_PX then
            local occupied = false
            for i = 1, n do
              if a.snap(tArr[i]) == snappedT then occupied = true; break end
            end
            if not occupied then
              pt.circle(snappedT, val, R_PREVIEW, cols.anchorActive)
              preview = { t = snappedT, val = val }
            end
          end
        elseif n >= 2 then
          local curveY = valToY(evalAtT(mouseT))
          if math.abs(my - curveY) <= HIT_PX then
            for i = 1, n - 1 do
              if mouseT >= tArr[i] and mouseT < tArr[i + 1] then
                segHover = i; break
              end
            end
          end
        end
      end
    end
  end

  -- Sticky seg hover: dbl-click cycle moves the curve away, geometric
  -- hover would drop on the next frame; pin holds until the mouse moves.
  if not segHover and segPin and segPin.id == a.dragId
     and segPin.segI < n then
    local mx, my = ImGui.GetMousePos(ctx)
    if math.abs(mx - segPin.mx) < 1 and math.abs(my - segPin.my) < 1 then
      segHover = segPin.segI
    else
      segPin = nil
    end
  end

  local activeSeg = (drag and drag.kind == 'tension' and drag.idx) or segHover
  if activeSeg and activeSeg < n then
    local a0, a1 = tArr[activeSeg], tArr[activeSeg + 1]
    local span   = math.max(1, math.ceil(tToX(a1) - tToX(a0)))
    local hpts   = {}
    for k = 0, span do
      local tt = a0 + (a1 - a0) * k / span
      hpts[#hpts + 1] = tt
      hpts[#hpts + 1] = util.clamp(evalAtT(tt), vMin, vMax)
    end
    pt.polyline(hpts, cols.anchorActive, 2.5)
  end

  pt.popClip()

  ----- Mouse handling

  local clicked       = ImGui.IsMouseClicked(ctx, 0)
  local doubleClicked = ImGui.IsMouseDoubleClicked(ctx, 0)
  local held          = ImGui.IsMouseDown(ctx, 0)

  if drag and not held then drag = nil; return false end

  -- Dbl-click on anchor: delete. Suppress the insert blob until the
  -- mouse leaves the click position, else it pops up where we just removed.
  if doubleClicked and hover and a.hovered then
    cb.onDelete(hover)
    local mx, my = ImGui.GetMousePos(ctx)
    previewSuppress = { x = mx, y = my }
    hover = nil
    return true
  end

  local function seedDrag(kind, idx)
    local mx, my = ImGui.GetMousePos(ctx)
    drag = { kind = kind, id = a.dragId, idx = idx,
             startMx = mx, startMy = my, moved = false }
    return mx, my
  end

  local function seedMove(idx)
    local mx, my = seedDrag('move', idx)
    drag.startMouseT = pt.fromScreen(mx, my)
  end

  -- Dbl-click on segment: cycle shape; pin so further dbl-clicks
  -- keep cycling the same target despite the curve moving under the mouse.
  if doubleClicked and segHover and a.hovered then
    cb.onCycleShape(segHover)
    local mx, my = ImGui.GetMousePos(ctx)
    segPin = { id = a.dragId, segI = segHover, mx = mx, my = my }
    return true
  end

  if not drag and clicked and hover and a.hovered then
    seedMove(hover)
    return true
  end

  if not drag and clicked and not hover and preview and a.hovered then
    local newIdx = cb.onInsert(preview.t, preview.val)
    if newIdx then seedMove(newIdx); return true end
  end

  if not drag and clicked and segHover and a.hovered then
    local A = events[segHover]
    local B = events[segHover + 1]
    if A and B and A.shape == 'bezier' then
      seedDrag('tension', segHover)
      drag.startTension = A.tension or 0
      drag.ax, drag.ay = tToX(tArr[segHover]),     valToY(A.val or 0)
      drag.bx, drag.by = tToX(tArr[segHover + 1]), valToY(B.val or 0)
    else
      seedDrag('inert', segHover)
    end
    return true
  end

  if not (drag and held) then return false end
  --contract: inert drag consumes input but never invokes callbacks; pure ImGui empty-area-move suppression
  if drag.kind == 'inert' then return true end

  local mx, my = ImGui.GetMousePos(ctx)

  -- 1px movement gate: a click that doesn't drag must not edit. Without
  -- this, the held branch overwrites click-time val on frame 1.
  if not drag.moved then
    if math.abs(mx - drag.startMx) < 1 and math.abs(my - drag.startMy) < 1 then
      return true
    end
    drag.moved = true
  end

  -- Tension drag: project mouse delta onto chord-perpendicular captured
  -- at click time. valSpan-magnitude perpendicular = full tension swing.
  -- s flips perp orientation so "drag toward A = increase tau" holds for
  -- both gradient signs (bezier τ is asymmetric in val).
  if drag.kind == 'tension' then
    local cdx, cdy = drag.bx - drag.ax, drag.by - drag.ay
    local cLen = math.sqrt(cdx*cdx + cdy*cdy)
    if cLen >= 1 then
      local s     = (drag.ay >= drag.by) and 1 or -1
      local nx,ny = s * cdy / cLen, -s * cdx / cLen
      local perp  = (mx - drag.startMx) * nx + (my - drag.startMy) * ny
      local tau   = util.clamp(drag.startTension - 2 * perp / valSpan, -1, 1)
      cb.onTension(drag.idx, tau)
    end
    return true
  end

  local i = drag.idx
  local A = events[i]
  if not A then drag = nil; return true end

  local mouseT, rawVal = pt.fromScreen(mx, my)
  local currT  = tArr[i]
  local prevT  = (i > 1) and tArr[i - 1] or -math.huge
  local nextT  = (i < n) and tArr[i + 1] or  math.huge

  local toVal = util.clamp(util.round(rawVal), vMin, vMax)
  local shifted = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0

  if shifted then
    local toT = util.clamp(mouseT, prevT + FREE_EPS_T, nextT - FREE_EPS_T)
    cb.onMoveFree(i, toT, toVal)
  else
    -- Strict-between-neighbours, integer-snap. lo/hi are the inclusive
    -- snap bounds: floor(prev)+1 and ceil(next)-1. lo > hi means there's
    -- no snapped t available between neighbours; t stays put, val moves.
    local target = util.round(mouseT)
    local lo = (i > 1) and (math.floor(prevT) + 1) or -math.huge
    local hi = (i < n) and (math.ceil (nextT) - 1) or  math.huge
    local toT = currT
    if lo <= hi then
      target = math.max(lo, math.min(hi, target))
      local startT = drag.startMouseT
      if (mouseT > startT and target > currT) or
         (mouseT < startT and target < currT) then
        toT = target
      end
    end
    cb.onMove(i, toT, toVal)
    -- Re-anchor startMouseT on actual snap movement, so back-tracking the
    -- mouse below startT after a snap-up still triggers the down branch.
    if toT ~= currT then drag.startMouseT = mouseT end
  end

  return true
end

return self

