-- See docs/masterMix.md for the model.

--reaper: reads GetMasterTrack + D_VOL + Track_GetPeakInfo(0/1 peak, 1024 loudness) + time_precise; writes via CSurf_OnVolumeChange
--shape: masterMix = { segment = { id = 'master', render } }   -- one shared toolbar segment

local ImGui = require 'imgui' '0.10'

local chrome, ctx = (...).chrome, (...).ctx
local colour = chrome.colour

local WIDTH      = 170
local BAR_H      = 8
local HANDLE_W   = 9      -- grab handle width, px
local HANDLE_H   = 13      -- grab handle height, px
local METER_MIN  = -60
local METER_MAX  = 6
local ZERO_FRAC  = (0 - METER_MIN) / (METER_MAX - METER_MIN)   -- where 0 dB sits across the bar
local DETENT_DB  = 0.7    -- a drag snaps to unity within this band of 0 dB
local PEAK_SMOOTH = 0.5   -- ~2-frame averaging on the bar fill (the raw peak is nervy)
local HOLD_TIME  = 1.5    -- seconds a peak is held before it releases to the current level

local function clamp01(v) return v < 0 and 0 or v > 1 and 1 or v end
local function px(v) return math.floor(v + 0.5) end           -- nearest pixel, for crisp non-AA rules
local function ampToDb(a) return a > 1e-6 and 20 * math.log(a, 10) or METER_MIN end
local function dbFrac(db) return clamp01((db - METER_MIN) / (METER_MAX - METER_MIN)) end

-- Channel 1024 returns loudness, but its scale is undocumented; treated as
-- linear amplitude here. See docs/masterMix.md § Loudness scale.
local function loudnessDb(raw) return ampToDb(raw) end

-- REAPER's own fader taper (matches a track fader): frac 0..1 <-> dB <-> vol.
local function volToFrac(vol)
  local db = vol > 1e-6 and 20 * math.log(vol, 10) or -150
  return clamp01(reaper.DB2SLIDER(db) / 1000)
end
local function fracToDb(frac) return reaper.SLIDER2DB(frac * 1000) end
local function dbToVol(db)     return db <= -150 and 0 or 10 ^ (db / 20) end

----- Crisp (non-AA) primitives: ReaImGui's AddLine/AddRect are anti-aliased with
----- no per-call toggle, so axis-aligned filled rects stand in for 1px rules.

local function hrule(dl, x0, x1, y, col) ImGui.DrawList_AddRectFilled(dl, px(x0), px(y), px(x1), px(y) + 1, col) end
local function vrule(dl, x, y0, y1, col) ImGui.DrawList_AddRectFilled(dl, px(x), px(y0), px(x) + 1, px(y1), col) end
local function chip(dl, x, y0, y1, col) ImGui.DrawList_AddRectFilled(dl, px(x), px(y0), px(x) + 2, px(y1), col) end
local function box(dl, x0, y0, x1, y1, col)
  hrule(dl, x0, x1, y0, col); hrule(dl, x0, x1, y1 - 1, col)
  vrule(dl, x0, y0, y1, col); vrule(dl, x1 - 1, y0, y1, col)
end

----- Meter bars

local function drawBar(dl, x, top, peak, holdDb, loudX)
  ImGui.DrawList_AddRectFilled(dl, x, top, x + WIDTH, top + BAR_H, colour('toolbar.meter.bg'))
  local frac = dbFrac(ampToDb(peak))
  if frac > 0 then
    local green = math.min(frac, ZERO_FRAC)
    ImGui.DrawList_AddRectFilled(dl, x, top, x + WIDTH * green, top + BAR_H, colour('toolbar.meter.fill'))
    if frac > ZERO_FRAC then
      ImGui.DrawList_AddRectFilled(dl, x + WIDTH * ZERO_FRAC, top, x + WIDTH * frac, top + BAR_H, colour('toolbar.meter.hot'))
    end
  end
  if loudX then vrule(dl, loudX, top, top + BAR_H, colour('toolbar.meter.loud')) end
  if holdDb > METER_MIN then chip(dl, x + WIDTH * dbFrac(holdDb), top, top + BAR_H, colour('toolbar.meter.peak')) end
end

----- Segment

local suppressDrag = false   -- a double-click reset holds off drag until the mouse releases
local peakL, peakR = 0, 0    -- frame-averaged bar fills
local holdL, holdR = METER_MIN, METER_MIN   -- held peak per channel, dB
local holdAtL, holdAtR = 0, 0               -- time_precise() when each hold last latched

-- Latch a higher peak and stamp the time; once HOLD_TIME elapses with nothing
-- louder, release the hold to the current level.
local function holdPeak(heldDb, latchedAt, db, now)
  if db >= heldDb or now - latchedAt >= HOLD_TIME then return db, now end
  return heldDb, latchedAt
end

local function render()
  local master = reaper.GetMasterTrack(0)
  if not master then return end

  local x, y = ImGui.GetCursorScreenPos(ctx)
  x, y = px(x), px(y)
  local H  = ImGui.GetFrameHeight(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)

  -- The whole rect is the fader; the meter bars ride its top and bottom edges.
  ImGui.InvisibleButton(ctx, '##masterFader', WIDTH, H)
  local active = ImGui.IsItemActive(ctx)
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    reaper.CSurf_OnVolumeChange(master, 1, false)   -- double-click resets to 0 dB
    suppressDrag = true
  elseif active and not suppressDrag then
    local mouseX = ImGui.GetMousePos(ctx)
    local db = fracToDb(clamp01((mouseX - x) / WIDTH))
    if math.abs(db) < DETENT_DB then db = 0 end     -- 0 dB detent
    reaper.CSurf_OnVolumeChange(master, dbToVol(db), false)
  end
  if not active then suppressDrag = false end

  local loudDb = loudnessDb(reaper.Track_GetPeakInfo(master, 1024))
  local loudX  = loudDb > METER_MIN and (x + WIDTH * dbFrac(loudDb)) or nil
  local rawL, rawR = reaper.Track_GetPeakInfo(master, 0), reaper.Track_GetPeakInfo(master, 1)
  peakL = peakL + (rawL - peakL) * PEAK_SMOOTH
  peakR = peakR + (rawR - peakR) * PEAK_SMOOTH
  local now = reaper.time_precise()
  holdL, holdAtL = holdPeak(holdL, holdAtL, ampToDb(rawL), now)
  holdR, holdAtR = holdPeak(holdR, holdAtR, ampToDb(rawR), now)
  drawBar(dl, x, y,             peakL, holdL, loudX)
  drawBar(dl, x, y + H - BAR_H, peakR, holdR, loudX)

  -- groove (a touch above centre), 0 dB detent tick, handle
  local vol = reaper.GetMediaTrackInfo_Value(master, 'D_VOL')
  hrule(dl, x, x + WIDTH, y + H / 2 - 1, colour('toolbar.fader.track'))
  vrule(dl, x + WIDTH * volToFrac(1), y + BAR_H, y + H - BAR_H, colour('toolbar.meter.border'))
  local handleX = px(x + WIDTH * volToFrac(vol))
  local hx0 = handleX - math.floor(HANDLE_W / 2)
  local hx1 = hx0 + HANDLE_W
  local hy0 = y + math.floor((H - HANDLE_H)/2)
  local hy1 = hy0 + HANDLE_H
  local grab    = active and colour('toolbar.sliderGrabActive') or colour('toolbar.sliderGrab')
  ImGui.DrawList_AddRectFilled(dl, hx0, hy0, hx1, hy1, grab)
  box(dl, hx0, hy0, hx1, hy1, colour('toolbar.meter.border'))   -- 1px non-AA frame on the grab
  box(dl, x, y, x + WIDTH, y+H, colour('toolbar.meter.border'))   -- 1px non-AA frame on the meter

  if active then   -- dB readout below the fader, tracking the handle
    local db  = vol > 1e-6 and 20 * math.log(vol, 10) or nil
    local str = db and string.format('%+.1f dB', db) or '-inf dB'
    local tw, th = ImGui.CalcTextSize(ctx, str)
    local fdl = ImGui.GetForegroundDrawList(ctx)   -- escape the toolbar child's clip rect
    local bx, by = px(handleX - tw / 2 - 4), y + H + 4
    ImGui.DrawList_AddRectFilled(fdl, bx, by, bx + tw + 8, by + th + 2, colour('toolbar.popupBg'))
    box(fdl, bx, by, bx + tw + 8, by + th + 2, colour('toolbar.meter.border'))
    ImGui.DrawList_AddText(fdl, bx + 4, by + 1, colour('toolbar.text'), str)
  end
end

return { segment = { id = 'master', render = render } }
