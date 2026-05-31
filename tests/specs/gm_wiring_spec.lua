-- Pins the mirror lifetime contract that trackerPage's wiring depends
-- on: the active group and the source snapshot survive pure navigation
-- but are cleared by ANY mutation command (the doBefore sweep whose
-- keep-set is navigation). mirrorPaste mirrors only while a source
-- snapshot is live, else it falls back to ordinary paste. BOTH copy
-- and mirrorMark must take that snapshot, or mark -> paste silently
-- degrades to plain paste. Real gm + real cmgr; fake tm as in
-- mirm_active_spec.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, flushes = 0 }, 0
  local tm = {}
  function tm:subscribe(s, fn) hooks[s] = fn end
  function tm:addEvent(e)      staged.add[#staged.add + 1] = e end
  function tm:assignEvent()    end
  function tm:deleteEvent()    end
  function tm:flush()
    staged.flushes = staged.flushes + 1
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end,
           subscribe = function() end }
end

local function note(ppq) return { evType = 'note', chan = 1, lane = 1,
  ppq = ppq, endppq = ppq + 240, pitch = 60, vel = 100 } end
local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['note:1'] = true } } } end

-- Faithfully mirrors trackerPage's real mirrorPaste gate: it stamps iff
-- a `mirrorSrc` snapshot is live, else falls back to ordinary paste.
-- Both mirrorMark AND copy snapshot that source (the documented
-- "mirrorSrc + active (mark/copy -> mirrorPaste)" lifetime). fell.v
-- records a fallback.
-- `sel` models a live selection; selRect() is tv:selectionAsRect (nil
-- once cleared). copy ends with selClear (clipboard:copy does), so the
-- page's source snapshot MUST hook doBefore('copy') -- a doAfter would
-- see the emptied selection. ctl exposes sel so tests can arm it.
local function wire(gm, cmgr, tm, ctl)
  local KEEP  = { cursorDown = true, copy = true,
                  mirrorMark = true, mirrorPaste = true }
  local mirrorSrc, fell = nil, { v = false }
  local function selRect() return ctl.sel and rect() or nil end
  local sc = cmgr:scope('tracker')
  sc:registerAll{
    cursorDown  = function() end,
    deleteSel   = function() end,
    copy        = function() ctl.sel = false end,   -- clipboard:copy selClears
    mirrorMark  = function()
      mirrorSrc = selRect()
      if mirrorSrc then gm:mark({ note(0) }, mirrorSrc) end
    end,
    mirrorPaste = function()
      if mirrorSrc then
        gm:stamp({ note(0) }, mirrorSrc, { ppq = 960, chan = 1 }); tm:flush()
      else fell.v = true end
    end,
  }
  cmgr:doBefore('copy', function() mirrorSrc = selRect() end)
  local clearOn = {}
  for name in pairs(sc.registered) do
    if not KEEP[name] then clearOn[#clearOn + 1] = name end
  end
  cmgr:doBefore(clearOn, function()
    mirrorSrc = nil
    gm:clearActive()
  end)
  cmgr:push('tracker')
  return fell
end

local function mk()
  local tm, staged = fakeTm()
  local cm   = fakeCm()
  local ctl  = { sel = true }   -- a live selection by default
  local gm = util.instantiate('groupManager', { tm = tm, cm = cm })
  local cmgr = util.instantiate('commandManager', { cm = cm })
  local fell = wire(gm, cmgr, tm, ctl)
  return gm, cmgr, staged, fell, ctl
end

return {
  {
    name = 'mark goes active; navigation preserves it; a mutation clears it',
    run = function()
      local gm, cmgr = mk()
      cmgr:invoke('mirrorMark')
      t.truthy(gm:activeGroup(), 'mark set active')
      cmgr:invoke('cursorDown')
      t.truthy(gm:activeGroup(), 'navigation did NOT clear active')
      cmgr:invoke('deleteSel')
      t.eq(gm:activeGroup(), nil, 'a mutation cleared active')
    end,
  },
  {
    name = 'mirrorMark then nav then mirrorPaste mirrors (does NOT fall back)',
    run = function()
      local gm, cmgr, staged, fell = mk()
      cmgr:invoke('mirrorMark')              -- mark: active + source snapshot
      cmgr:invoke('cursorDown')              -- nav keeps both
      cmgr:invoke('mirrorPaste')
      t.eq(fell.v, false, 'mark fed the source; paste must not fall back')
      t.eq(#staged.add, 1, 'one mirror copy staged at the anchor')
      t.truthy(staged.flushes > 0, 'the staged copy was flushed (materialised)')
    end,
  },
  {
    name = 'copy snapshots the source BEFORE its own selClear',
    run = function()
      local gm, cmgr, staged, fell = mk()  -- ctl.sel = true
      cmgr:invoke('copy')                    -- body selClears; hook ran first
      cmgr:invoke('mirrorPaste')
      t.eq(fell.v, false, 'copy-time snapshot survived the selClear')
      t.eq(#staged.add, 1, 'one mirror copy staged')
      t.truthy(staged.flushes > 0, 'and it was flushed')
    end,
  },
  {
    name = 'mirrorPaste mirrors while pristine, falls back after a mutation',
    run = function()
      local gm, cmgr, staged, fell = mk()
      cmgr:invoke('copy')
      cmgr:invoke('cursorDown')              -- nav keeps pristine
      cmgr:invoke('mirrorPaste')
      t.truthy(gm:activeGroup(), 'pristine: stamp seeded a group')
      t.eq(#staged.add, 1, 'one copy staged at the anchor')
      t.eq(fell.v, false, 'did not fall back while pristine')

      cmgr:invoke('copy')
      cmgr:invoke('deleteSel')               -- mutation clears pristine
      cmgr:invoke('mirrorPaste')
      t.eq(fell.v, true, 'mutated since copy -> ordinary paste fallback')
      t.eq(#staged.add, 1, 'fallback staged no new mirror copy')
    end,
  },
}
