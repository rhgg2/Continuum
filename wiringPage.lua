-- See docs/wiringPage.md for the model.
-- @noindex
--
-- wiringPage is the wiring page's controller — the object coord drives. It owns
-- the stack (rm/wm/wv) and delegates all rendering to wiringRender. The two
-- roles — manage the stack vs. draw it — live in separate modules; the renderer
-- is handed only wv and never reaches wm/rm.

--contract: constructs the substack (rm/wm local, only wv leaves); the renderer is handed wv, never wm/rm
--contract: wiring is project-wide — bind() takes no take and never re-keys cm; tracker take and sampler track are unaffected
--contract: render hooks delegate to wiringRender; lifecycle (unbind/enableLive/tick) drives wv/wr directly
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end

local cm, cmgr, chrome, gui, modalHost =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost

-- rm/wm stay local to this chunk; only wv leaves, handed to the renderer, so the
-- renderer can't reach wm/rm — every graph query and mutation flows through wv.
local rm = util.instantiate('routingManager')
local wm = util.instantiate('wiringManager', { cm = cm, rm = rm })
local wv = util.instantiate('wiringView',    { cm = cm, cmgr = cmgr, wm = wm })

local wr = util.instantiate('wiringRender',
  { wv = wv, cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, modalHost = modalHost })

local wp = {}

----------- PUBLIC

----- Page lifecycle — wiring is project-wide, so bind takes no take

--contract: bind takes no take — wiring is project-wide. coord may call with no args (or a take, ignored).
function wp:bind() end
function wp:unbind() wr:closeTransients() end

--contract: turn on live recompile — every wiringChanged drives a diff+apply, plus one immediate reconcile pass to sync REAPER with the persisted graph at boot. Idempotent. Called once from continuum after registration.
function wp:enableLive() wv:enableLive() end

--contract: per-frame poll; drives wm:pollUndo to detect REAPER undo/redo of wiring gestures (scratch P_EXT divergence) and re-issue wiringChanged{kind='load'}. Called from coordinator.frame regardless of which page is active.
function wp:tick() wv:pollUndo() end

----- Page interface — render delegates to the renderer
function wp:renderToolbarBits(ctx)          return wr:renderToolbarBits(ctx) end
function wp:renderBody(ctx, w, h, dispatch) return wr:renderBody(ctx, w, h, dispatch) end
function wp:renderStatusBar(ctx)            return wr:renderStatusBar(ctx) end
function wp:focusState()                    return wr:focusState() end

return wp
