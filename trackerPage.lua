-- See docs/trackerPage.md for the model.
--
-- trackerPage is the tracker's controller — the object coord drives. It owns
-- the stack (mm/tm/gm/tv) and the take lifecycle, and delegates all rendering
-- to trackerRender. The two roles — manage the stack vs. draw it — live in
-- separate modules; the renderer is handed only tv and never reaches below it.

--contract: mm/tm/gm local, only tv leaves; take lifecycle drives tm, view-state drives tv
--contract: the bound take follows the arrange cursor; renderBody rebinds, then arms the external-mutation watcher
--contract: render hooks delegate to trackerRender; lifecycle (bind/unbind/dropTake/reload) is native here
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end

local cm, ds, cmgr, chrome, gui, modalHost, facade, help =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).help

local function arrange() return facade.get('arrange') end

-- mm/tm/gm stay local to this chunk; only tv leaves, handed to the renderer.
-- coord drives the take lifecycle on tm directly; tv owns only its own view-state seams.
local mm = util.instantiate('midiManager',    { take = nil })
local tm = util.instantiate('trackerManager', { mm = mm, cm = cm, ds = ds })
local gm = util.instantiate('groupManager',   { tm = tm, ds = ds })
local pa = util.instantiate('paramAutomation', { cm = cm, ds = ds, facade = facade })
local tv = util.instantiate('trackerView',    { tm = tm, cm = cm, ds = ds, cmgr = cmgr, gm = gm, pa = pa })

local tr = util.instantiate('trackerRender',
  { tv = tv, cm = cm, ds = ds, cmgr = cmgr, chrome = chrome,
    gui = gui, modalHost = modalHost, help = help, facade = facade })

local tp = {}
local lastHash = nil   -- bound take's last-seen MIDI hash; external-mutation watcher baseline
-- Set on unbind: forces the next bindFromCursor to re-key the shared cm even if
-- the cursor take is unchanged, since another page may have re-keyed it meanwhile.
local wasDormant = false

--reaper: MIDI_GetHash on the bound take — the external-mutation watcher baseline
local function takeHash()
  local take = tm:currentTake(); if not take then return nil end
  local ok, h = reaper.MIDI_GetHash(take, false)
  return ok and h or nil
end

----------- PUBLIC

----- Take lifecycle (take ops on tm, view-state on tv)

function tp:currentTake() return tm:currentTake() end

--contract: with a take, bind it on tm and seed tv; no arg = activation, bind from the cursor
function tp:bind(t)
  if not t then return self:bindFromCursor() end
  tm:bindTake(t)
  tv:seedSharedSlots()
  pa:apply()
end
function tp:unbind() tm:bindTake(nil); wasDormant = true end

--contract: if take is destroyed, detach tm and blank the grid. Distinct from unbind.
function tp:dropTake() tm:detach(); tv:dropGrid() end

--contract: for coord's external-mutation watcher; re-reads the bound take, no swap
function tp:reloadFromReaper() tm:reloadFromReaper() end

--contract: rebind to the cursor take on change, then hash-diff for external edits. See docs/trackerPage.md § Bind from the cursor.
function tp:bindFromCursor()
  local cur = arrange().currentTake()
  if wasDormant or cur ~= tm:currentTake() then
    wasDormant = false
    if cur then self:bind(cur) else self:dropTake() end
    lastHash = nil
  elseif cur and lastHash then
    local h = takeHash()
    if h and h ~= lastHash then tm:reloadFromReaper() end
  end
end

-- Arrange opens take properties without diving: bind to it (so tv reads its
-- model), then open the modal. The cursor drives the bind back, so no restore.
facade.publish('tracker', {
  openTakeProperties = function(item)
    local take = item and reaper.GetActiveTake(item)
    if not take then return end
    if take ~= tp:currentTake() then tp:bind(take) end
    tr:openTakeProperties{}
  end,
  -- Swing edits: bind each affected take through tm (markSwingStale) to re-realise, restore after.
  -- am owns the walk; tm owns the bind.
  reswingTakes = function(takes)
    local origTake = tm:currentTake()
    for _, take in ipairs(takes) do
      if take ~= origTake then tm:bindTake(take, { markSwingStale = true }) end
    end
    if tm:currentTake() ~= origTake then tm:bindTake(origTake) end
  end,
  -- Take-context + tier-spanning slot writes for the off-stack editor page.
  timeSig           = function()        return tv:timeSig()      end,
  cursorAnchor      = function()        return tv:cursorAnchor() end,
  setSwingComposite = function(name, c, tier) tv:setSwingComposite(name, c, tier) end,
})

----- Page interface — render delegates to the renderer; the watcher brackets the frame

function tp:toolbarSegments() return tr:toolbarSegments() end
function tp:renderStatusBar(ctx)   return tr:renderStatusBar(ctx) end
function tp:focusState()           return tr:focusState() end

--contract: follow the cursor, draw, then snapshot the take hash as next frame's watcher baseline
function tp:renderBody(ctx, w, h, dispatch)
  self:bindFromCursor()
  tr:renderBody(ctx, w, h, dispatch)
  lastHash = takeHash()
end

return tp
