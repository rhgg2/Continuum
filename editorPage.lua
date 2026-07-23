-- @noindex
-- editorPage: page controller — owns panes + renderer, publishes 'editor' facade. see docs/editorPage.md.

--contract: constructs swing/temper panes + renderer; publishes the 'editor' facade
--contract: render delegates to editorRender; close returns to coord's previous page
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end

local cm, ds, cmgr, chrome, gui, modalHost, facade, lib =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).lib
local swingEditor  = util.instantiate('swingEditor',
  { cm = cm, ds = ds, chrome = chrome, ctx = gui.ctx, gui = gui, facade = facade, modalHost = modalHost, lib = lib })
local temperEditor = util.instantiate('temperEditor',
  { cm = cm, chrome = chrome, ctx = gui.ctx, gui = gui, facade = facade, modalHost = modalHost })

local er = util.instantiate('editorRender',
  { swingEditor = swingEditor, temperEditor = temperEditor,
    cmgr = cmgr, chrome = chrome, gui = gui, modalHost = modalHost })

local ep = {}

----------- PUBLIC

-- Fast path: editTuning/editSwing set pane + selection via the renderer, then
-- switch the page (they hold coord). Mirrors samplePage's diveToSampler.
facade.publish('editor', {
  edit = function(pane, name) er:edit(pane, name) end,
})

----- Page lifecycle — no take binding; pane state persists across visits
function ep:bind()   end
function ep:unbind() er:unbind() end

----- Page interface — render delegates to the renderer
function ep:toolbarSegments()               return er:toolbarSegments() end
function ep:renderBody(ctx, w, h, dispatch) return er:renderBody(ctx, w, h, dispatch) end
function ep:renderStatusBar(ctx)            return er:renderStatusBar(ctx) end
function ep:focusState()                    return er:focusState() end

return ep
