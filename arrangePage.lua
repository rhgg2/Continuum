-- See docs/arrangePage.md for the model.
-- @noindex
--
-- arrangePage is the arrange page's controller — the object coord drives. It
-- owns the stack (am/av) and delegates all rendering to arrangeRender. The two
-- roles — manage the stack vs. draw it — live in separate modules; the renderer
-- is handed only av and never reaches am.

--contract: constructs the substack (am local, only av leaves); the renderer is handed av, never am
--contract: arrange is project-wide — bind() takes no take and never re-keys cm
--contract: render hooks delegate to arrangeRender; seedCursor drive av directly
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end

local cm, ds, cmgr, chrome, gui, modalHost, facade, eventMeta, help =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).eventMeta, (...).help

-- am stays local to this chunk; only av leaves, handed to the renderer, so the
-- renderer can't reach am — every project query and mutation flows through av.
local am = util.instantiate('arrangeManager', { cm = cm, ds = ds, facade = facade, eventMeta = eventMeta })
local av = util.instantiate('arrangeView',    { cm = cm, cmgr = cmgr, facade = facade, am = am })
local ar = util.instantiate('arrangeRender',  { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui,
                                                modalHost = modalHost, help = help, av = av })

local ap = {}

---------- PUBLIC

----- Page lifecycle — arrange is project-wide, so bind takes no take

--contract: bind takes no take — arrange is project-wide; coord may call with nil or a take.
function ap:bind() end
function ap:unbind() av:dropBand(); av:dropReplaceMode() end

--contract: seeds the cursor from am:initialCursor (selected take, else edit cursor); no selection.
function ap:seedCursorFromReaper() av:seedCursor() end

----- Arrange service surface — av passthroughs
facade.publish('arrange', {
  currentTrackIdx = function()        return av:cursorCol()       end,
  tracks          = function()        return av:projectTracks()   end,
  midiSlots       = function(trackIdx) return av:midiSlots(trackIdx) end,
  visibleTakes    = function(fromCol, toCol, qnLo, qnHi)
    return av:visibleTakes(fromCol, toCol, qnLo, qnHi)
  end,
  instanceAt      = function(trackIdx, qn) return av:instanceAt(trackIdx, qn) end,
  takeForSlot     = function(trackIdx, slotIdx) return av:takeForSlot(trackIdx, slotIdx) end,
  trackIdxForGuid = function(guid)     return av:trackIdxForGuid(guid) end,
  trackHandle     = function(trackIdx) return av:trackHandle(trackIdx) end,
  keyForSlot      = function(slotIdx)  return av:keyForSlot(slotIdx) end,
  nextFreeSlot    = function(trackIdx) return av:nextFreeSlot(trackIdx) end,
  mintParkedTake  = function(trackIdx, name, lengthQN, srcTake)
    return av:mintParkedTake(trackIdx, name, lengthQN, srcTake)
  end,
  newTakeBelow    = function(inst, name, lengthQN) return av:newTakeBelow(inst, name, lengthQN) end,
  duplicateBelow  = function(take) return av:duplicateBelow(take) end,
  stepVariant     = function(take, dir) return av:stepVariant(take, dir) end,
  dropSlot        = function(trackIdx, slotIdx, qnPos) return av:dropSlot(trackIdx, slotIdx, qnPos) end,
  renameSlot      = function(trackIdx, slotIdx, name)  av:renameSlot(trackIdx, slotIdx, name) end,
  deleteSlot      = function(trackIdx, slotIdx)        av:deleteSlot(trackIdx, slotIdx) end,
  deleteTake      = function(take) av:deleteTake(take) end,
  hasPlacedTakes  = function() return av:hasPlacedTakes() end,
  isParkedTake    = function(take) return av:isParkedTake(take) end,
  ownerTrack      = function(take) return av:ownerTrack(take) end,
  findTake        = function(take) return av:findTake(take) end,
  slotOfTake      = function(take) return av:slotOfTake(take) end,
  seekInstance    = function(take, qn, back) return av:seekInstance(take, qn, back) end,
  playPositionQN  = function()     return av:playPositionQN() end,
  loopRangeQN     = function()     return av:loopRangeQN()    end,
  editCursorQN    = function()     return av:editCursorQN()   end,
  setCursorAt     = function(trackIdx, qn) av:setCursorAt(trackIdx, qn) end,
  setEditCursorQN = function(qn)   av:setEditCursorQN(qn) end,
  setLoopRangeQN  = function(loQN, hiQN) av:setLoopRangeQN(loQN, hiQN) end,
  clearLoopRange  = function()     av:clearLoopRange() end,
  playFromQN      = function(qn)   av:playFromQN(qn) end,
  loopTo          = function(loQN, hiQN) av:loopTo(loQN, hiQN) end,
  reswingAll             = function(name) av:reswingAll(name) end,
  takesUsing             = function(name) return av:takesUsing(name) end,
  tempersInUse           = function()     return av:tempersInUse()  end,
})

----- Page interface — render delegates to the renderer
function ap:toolbarSegments() return ar:toolbarSegments() end
function ap:renderBody(_, w, h, dispatch) return ar:renderBody(_, w, h, dispatch) end
function ap:statusSegments()       return ar:statusSegments() end
function ap:focusState()           return ar:focusState() end

return ap
