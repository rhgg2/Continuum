-- projext undo (design/archive/projext-undo.md): undoable project-scope slots mirror
-- onto the scratch track's P_EXT, which REAPER undo rewinds natively; projext
-- does not. pollUndo detects a rewound mirror through the two-level hash
-- manifest, copies only the genuinely diverged slots back into projext, and
-- fires 'projectRewound' so faces can reload.

local t    = require('support')
local util = require('util')

local function fresh()
  local reaper = require('fakeReaper').new()
  _G.reaper = reaper
  local ps = util.instantiate('pextStore')
  return ps, reaper
end

-- REAPER undo in fake terms: track chunks (trackExt) rewind to an earlier
-- snapshot and the state count ticks; projext survives untouched.
local function snapshot(reaper) return util.clone(reaper._state.trackExt) end
local function rewindTo(reaper, snap)
  reaper._state.trackExt = util.clone(snap)
  reaper._state.projStateCount = reaper._state.projStateCount + 1
end

return {
  {
    name = 'undo restores an undoable project slot and fires its watch group',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ slots = { 'blob' } }
      local diverged
      ps:watch({ { scope = 'project', slot = 'blob' } }, function(d) diverged = d end)
      ps:assign('project', 'blob', { v = 1 })
      local snap = snapshot(reaper)
      ps:assign('project', 'blob', { v = 2 })
      rewindTo(reaper, snap)
      ps:pollUndo()
      t.eq(ps:get('project', 'blob').v, 1, 'projext converged to the pre-edit value')
      t.truthy(diverged, 'watch group fired for the rewound slot')
      t.eq(diverged[1].slot, 'blob')
    end,
  },

  {
    name = 'a plain (undeclared) slot never rewinds',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ slots = { 'blob' } }
      ps:assign('project', 'blob',  { v = 1 })
      ps:assign('project', 'plain', { v = 1 })
      local snap = snapshot(reaper)
      ps:assign('project', 'blob',  { v = 2 })
      ps:assign('project', 'plain', { v = 2 })
      rewindTo(reaper, snap)
      ps:pollUndo()
      t.eq(ps:get('project', 'blob').v,  1, 'undoable slot rewound')
      t.eq(ps:get('project', 'plain').v, 2, 'plain slot survives undo')
    end,
  },

  {
    name = 'resync copies back only the diverged slots',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ prefixes = { 'k.' } }
      local rewound
      ps:subscribe('projectRewound', function(slots) rewound = slots end)
      ps:assign('project', 'k.a', { v = 1 })
      ps:assign('project', 'k.b', { v = 1 })
      local snap = snapshot(reaper)
      ps:assign('project', 'k.a', { v = 2 })
      rewindTo(reaper, snap)
      ps:pollUndo()
      t.truthy(rewound, 'projectRewound fired')
      t.eq(#rewound, 1, 'only the slot the undo actually crossed')
      t.eq(rewound[1], 'k.a')
      t.eq(ps:get('project', 'k.a').v, 1)
      t.eq(ps:get('project', 'k.b').v, 1)
    end,
  },

  {
    name = 'own writes never read as a rewind',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ slots = { 'blob' } }
      local fired = false
      ps:subscribe('projectRewound', function() fired = true end)
      ps:assign('project', 'blob', { v = 1 })
      -- Unrelated structural edit ticks the state counter; nothing rewound.
      reaper._state.projStateCount = reaper._state.projStateCount + 1
      ps:pollUndo()
      t.falsy(fired, 'no rewind from our own writes')
      t.eq(ps:get('project', 'blob').v, 1)
    end,
  },

  {
    name = 'slot deletion round-trips: undo restores, redo re-deletes',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ slots = { 'blob' } }
      ps:assign('project', 'blob', { v = 1 })
      local before = snapshot(reaper)
      ps:assign('project', 'blob', util.REMOVE)
      local after = snapshot(reaper)
      rewindTo(reaper, before)      -- undo the delete
      ps:pollUndo()
      t.eq(ps:get('project', 'blob').v, 1, 'undo restores the deleted slot')
      rewindTo(reaper, after)       -- redo it
      ps:pollUndo()
      t.eq(ps:get('project', 'blob'), nil, 'redo re-deletes the slot')
    end,
  },

  {
    name = 'a project switch reseeds; it never reads as a rewind',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ slots = { 'blob' } }
      local fired = false
      ps:subscribe('projectRewound', function() fired = true end)
      ps:assign('project', 'blob', { v = 1 })
      -- A real switch invalidates the old scratch handle: drop its track.
      local old = reaper._state.projExt['continuum_wiring/scratch']
      for i, track in ipairs(reaper._state.projectTracks) do
        if reaper._state.trackGuids[track] == old then
          table.remove(reaper._state.projectTracks, i); break
        end
      end
      -- The other project's scratch: different guid, its own (empty) mirror
      -- root — non-empty raw marks "has a mirror", selecting the adopt path.
      local alien = { __track = 'alien' }
      table.insert(reaper._state.projectTracks, alien)
      reaper._state.trackGuids[alien] = '{ALIEN}'
      reaper._state.projExt['continuum_wiring/scratch'] = '{ALIEN}'
      reaper._state.trackExt[tostring(alien) .. '/P_EXT:ctm_ps.root'] = util.serialise({})
      reaper._state.projStateCount = reaper._state.projStateCount + 1
      ps:pollUndo()
      t.falsy(fired, 'guid swap is a reseed, not a rewind')
      t.eq(ps:get('project', 'blob').v, 1, 'projext untouched')
      -- The new scratch is now live: writes + undo work against it.
      ps:assign('project', 'blob', { v = 2 })
      local snap = snapshot(reaper)
      ps:assign('project', 'blob', { v = 3 })
      rewindTo(reaper, snap)
      ps:pollUndo()
      t.eq(ps:get('project', 'blob').v, 2, 'undo works against the adopted scratch')
    end,
  },

  {
    name = 'scratch deleted: resync no-ops; the next write re-mints and remirrors',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ prefixes = { 'k.' } }
      ps:assign('project', 'k.a', { v = 1 })
      ps:assign('project', 'k.b', { v = 1 })
      -- Delete the scratch track outright.
      local guid = reaper._state.projExt['continuum_wiring/scratch']
      for i, track in ipairs(reaper._state.projectTracks) do
        if reaper._state.trackGuids[track] == guid then
          table.remove(reaper._state.projectTracks, i); break
        end
      end
      reaper._state.projStateCount = reaper._state.projStateCount + 1
      local fired = false
      ps:subscribe('projectRewound', function() fired = true end)
      ps:pollUndo()
      t.falsy(fired, 'no scratch, no resync')
      -- Next write re-mints and remirrors every known slot from projext:
      -- an undo over the NEW scratch must restore k.b, not just the slot written.
      ps:assign('project', 'k.a', { v = 2 })
      local snap = snapshot(reaper)
      ps:assign('project', 'k.b', { v = 2 })
      rewindTo(reaper, snap)
      ps:pollUndo()
      t.eq(ps:get('project', 'k.b').v, 1, 'remirrored slot rides undo on the re-minted scratch')
      t.eq(ps:get('project', 'k.a').v, 2, 'unrewound slot untouched')
    end,
  },

  {
    name = 'scratch deleted and re-minted by another tenant: protection survives',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ prefixes = { 'k.' } }
      ps:assign('project', 'k.a', { v = 1 })
      ps:assign('project', 'k.b', { v = 1 })
      -- Delete the scratch, then re-mint it as rm's per-frame heartbeat does —
      -- before ps sees anything. The guid changes but this is NOT a project
      -- switch; treating it as one would silently drop all mirror protection.
      local guid = reaper._state.projExt['continuum_wiring/scratch']
      for i, track in ipairs(reaper._state.projectTracks) do
        if reaper._state.trackGuids[track] == guid then
          table.remove(reaper._state.projectTracks, i); break
        end
      end
      require('scratch').track()
      reaper._state.projStateCount = reaper._state.projStateCount + 1
      local fired = false
      ps:subscribe('projectRewound', function() fired = true end)
      ps:pollUndo()
      t.falsy(fired, 're-mint is not a rewind')
      -- That poll remirrored from projext: both slots ride undo again at once.
      local snap = snapshot(reaper)
      ps:assign('project', 'k.b', { v = 2 })
      rewindTo(reaper, snap)
      ps:pollUndo()
      t.eq(ps:get('project', 'k.b').v, 1, 'undo works across the re-mint')
      t.eq(ps:get('project', 'k.a').v, 1)
    end,
  },

  {
    name = 'a fresh session seeds from the mirror and still detects a rewind',
    run = function()
      local ps, reaper = fresh()
      ps:declareUndoable{ slots = { 'blob' } }
      ps:assign('project', 'blob', { v = 1 })
      local snap = snapshot(reaper)
      ps:assign('project', 'blob', { v = 2 })
      -- Continuum restarts mid-session: a fresh engine over the same project.
      local ps2 = util.instantiate('pextStore')
      ps2:declareUndoable{ slots = { 'blob' } }
      ps2:pollUndo()                -- first tick seeds the expected state
      rewindTo(reaper, snap)        -- then the user hits undo
      ps2:pollUndo()
      t.eq(ps2:get('project', 'blob').v, 1, 'rewind detected from a seeded session')
    end,
  },

  {
    name = 'undo across a metadata edit reloads the pool and restores detune',
    run = function()
      local reaper = require('fakeReaper').new()
      _G.reaper = reaper
      reaper:bindTake('take1', 'item1', 'track1', 16)
      reaper:setResolution(240)
      -- Production wiring: ONE ps shared by the polled engine and mm's eventMeta.
      local ps = util.instantiate('pextStore')
      local em = util.instantiate('eventMeta', { ps = ps })
      local path = assert(package.searchpath('midiManager', package.path))
      local mm = assert(loadfile(path))({ take = 'take1', eventMeta = em })
      local token
      mm:modify(function()
        token = mm:add({ evType = 'note', ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
                         chan = 1, pitch = 60, vel = 96, lane = 1, detune = -30, delay = 0 })
      end)
      local snap = snapshot(reaper)
      mm:modify(function() mm:assign(token, { detune = 0 }) end)
      rewindTo(reaper, snap)
      ps:pollUndo()
      local seen = 0
      for _, note in mm:notes() do
        seen = seen + 1
        t.eq(note.detune, -30, 'undo restored the detune tag')
      end
      t.eq(seen, 1, 'the note survived the reload')
    end,
  },
}
