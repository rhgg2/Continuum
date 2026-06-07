-- See docs/trackerPage.md for the model.
--
-- trackerPage is the tracker's controller — the object coord drives. It owns
-- the stack (mm/tm/gm/tv) and the take lifecycle, and delegates all rendering
-- to trackerRender. The two roles — manage the stack vs. draw it — live in
-- separate modules; the renderer is handed only tv and never reaches below it.

--contract: constructs the substack (mm/tm/gm local, only tv leaves); tm is touched solely through tv
--contract: the bound take follows the arrange cursor; renderBody rebinds, then arms the external-mutation watcher
--contract: render hooks delegate to trackerRender; lifecycle (bind/unbind/dropTake/reload) is native here
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end

local cm, cmgr, chrome, gui, modalHost, facade =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade

local function arrange() return facade.get('arrange') end

-- mm/tm/gm stay local to this chunk; only tv leaves, handed to the renderer.
-- Lifecycle drives the stack through tv's passthroughs, so tm is owned by one
-- layer (tv) and reached by nobody above it.
local mm = util.instantiate('midiManager',    { take = nil })
local tm = util.instantiate('trackerManager', { mm = mm, cm = cm })
local gm = util.instantiate('groupManager',   { tm = tm, cm = cm })
local tv = util.instantiate('trackerView',    { tm = tm, cm = cm, cmgr = cmgr, gm = gm })

local renderer = util.instantiate('trackerRender',
  { tv = tv, cm = cm, cmgr = cmgr, chrome = chrome,
    gui = gui, modalHost = modalHost, facade = facade })

local tp = {}
local lastHash = nil   -- bound take's last-seen MIDI hash; external-mutation watcher baseline

----------- PUBLIC

----- Take lifecycle (drives the stack through tv)

function tp:currentTake() return tv:currentTake() end

--contract: bind/unbind drive the take via tv; the page owns the cm/mm swap for its stack
function tp:bind(t)
  tv:bindTake(t)
  if t then tv:seedSharedSlots() end
end
function tp:unbind() renderer:closeTransients(); tv:bindTake(nil) end

--contract: take destroyed under us (coord's ValidatePtr2 watcher) — unbind and blank the grid so the placeholder reappears. Distinct from unbind, which is the dormant seam.
function tp:dropTake() renderer:closeTransients(); tv:detach(); tv:dropGrid() end

--contract: for coord's external-mutation watcher; re-reads the bound take, no swap
function tp:reloadFromReaper() tv:reloadFromReaper() end

--contract: rebind to the cursor take on change, then hash-diff for external edits. See docs/trackerPage.md § Bind from the cursor.
function tp:bindFromCursor()
  local cur = arrange().currentTake()
  if cur ~= tv:currentTake() then
    if cur then self:bind(cur) else self:dropTake() end
    lastHash = nil
  elseif cur and lastHash then
    local h = tv:takeHash()
    if h and h ~= lastHash then tv:reloadFromReaper() end
  end
end

-- Arrange opens take properties without diving: bind to it (so tv reads its
-- model), then open the modal. The cursor drives the bind back, so no restore.
facade.publish('tracker', {
  openTakeProperties = function(item)
    local take = item and reaper.GetActiveTake(item)
    if not take then return end
    if take ~= tp:currentTake() then tp:bind(take) end
    renderer:openTakeProperties{}
  end,
})

----- Page interface — render delegates to the renderer; the watcher brackets the frame

function tp:renderToolbarBits(ctx) return renderer:renderToolbarBits(ctx) end
function tp:renderStatusBar(ctx)   return renderer:renderStatusBar(ctx) end
function tp:focusState()           return renderer:focusState() end

--contract: follow the cursor, draw, then snapshot the take hash as next frame's watcher baseline
function tp:renderBody(ctx, w, h, dispatch)
  self:bindFromCursor()
  renderer:renderBody(ctx, w, h, dispatch)
  lastHash = tv:takeHash()
end

return tp
