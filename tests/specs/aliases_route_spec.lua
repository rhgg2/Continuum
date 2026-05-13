-- Phase 3: edit routing. Relative nudges on aliased children compose
-- into the spec's per-field op-list (with coalescence on literal-arg
-- adds); plain events keep the pre-aliases mutation path.

local t = require('support')

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
              chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, uuid = 1 }
  for k, v in pairs(extras) do n[k] = v end
  return n
end

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

return {
  --------------------------------------------------------------------
  -- Aliased child: pitch op-list grows from empty to one entry
  --------------------------------------------------------------------
  {
    name = 'aliased pitch nudge appends to empty op-list; root unchanged',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)
      h.cmgr:invoke('nudgeFineUp')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.truthy(root, 'root present')
      t.deepEq(root.children[1].xform.pitch, {{'add', 1}})
      t.deepEq(root.children[1].xform.ppqL,  {{'add', 240}}, 'ppqL op untouched')
      t.eq(root.pitch, 60, 'root pitch unchanged')
    end,
  },

  --------------------------------------------------------------------
  -- Plain event: identical to today
  --------------------------------------------------------------------
  {
    name = 'plain pitch nudge mutates the note directly; no aliases written',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { {
          ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
          detune = 0, delay = 0,
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('nudgeFineUp')

      local notes = h.fm:dump().notes
      t.eq(#notes, 1)
      t.eq(notes[1].pitch, 61)
      t.falsy(notes[1].children)
    end,
  },

  --------------------------------------------------------------------
  -- Two same-direction nudges land as a single coalesced trailing add
  --------------------------------------------------------------------
  {
    name = 'two same-direction nudges coalesce into one trailing add',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)
      h.cmgr:invoke('nudgeFineUp')
      h.cmgr:invoke('nudgeFineUp')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.children[1].xform.pitch, {{'add', 2}},
               'single coalesced trailing add')
    end,
  },

  --------------------------------------------------------------------
  -- Selection contains a root AND its aliased child: localRoots
  -- filters the child out so we don't double-add the delta (root
  -- direct-bumped, child's spec append would compound on rebuild).
  -- Only the root's pitch moves; spec stays untouched.
  --------------------------------------------------------------------
  {
    name = 'nudge selection root+child: child filtered, spec.pitch untouched, only root pitch moves',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)

      local noteCol
      for ci, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then noteCol = ci; break end
      end
      h.ec:setSelection{ row1 = 0, row2 = 1, col1 = noteCol, col2 = noteCol,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('nudgeFineUp')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(root.pitch, 61, 'root bumped once by direct assign')
      t.deepEq(root.children[1].xform.pitch, {{'add', 1}},
        'spec pitch unchanged — child filtered, no second [add 1] appended')
    end,
  },

  --------------------------------------------------------------------
  -- Save → reload → rebuild → route round-trip. specOf does not
  -- persist; on a freshly-seeded harness the walker must rebuild it
  -- from the materialised event's parentUuid + the root's aliases
  -- list. The first relative edit after a cold start has to land on
  -- the right spec node.
  --------------------------------------------------------------------
  {
    name = 'cold-start round-trip: specOf repopulates; relative edit routes onto the live spec',
    run = function(harness)
      local hA = harness.mk{
        seed = { notes = { rootNote{
          children = {
            { xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }
      local dumpA = hA.fm:dump()

      local hB = harness.mk{ seed = { notes = dumpA.notes } }
      local kid
      for _, n in ipairs(hB.fm:dump().notes) do
        if n.parentUuid == 1 then kid = n end
      end
      t.truthy(kid, 'aliased kid present on cold-loaded harness B')
      t.truthy(hB.tm:specOf(kid.uuid),
               'specOf repopulated from cold state on first rebuild')

      t.truthy(hB.tm:routeRelative(kid, { pitch = { 'add', 1 } }))
      hB.tm:flush()

      local root = rootByUuid(hB.fm:dump().notes, 1)
      t.deepEq(root.children[1].xform.pitch, {{'add', 2}},
               'spec pitch op-list grew (1 from seed, +1 from route, coalesced)')

      local kidB
      for _, n in ipairs(hB.fm:dump().notes) do
        if n.parentUuid == 1 then kidB = n end
      end
      t.eq(kidB.pitch, 62, 'materialised kid re-emits at root+2')
      t.eq(kidB.ppq,   240)
    end,
  },

  --------------------------------------------------------------------
  -- Multi-row position nudge over a selection containing an aliased
  -- kid: kid's ppqL op-list grows by [add logPerRow]. Previously the
  -- multi path stamped the kid directly and the rebuild overwrote the
  -- stamp from the unchanged spec, silently no-opping.
  --------------------------------------------------------------------
  {
    name = 'multi position nudge: aliased kid spec.ppqL gains [add δ]; resolved ppq follows',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          children = {
            { xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local noteCol
      for ci, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then noteCol = ci; break end
      end
      h.ec:setSelection{ row1 = 2, row2 = 2, col1 = noteCol, col2 = noteCol,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('nudgeForward')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.children[1].xform.ppqL, {{'add', 720}},
               'spec ppqL coalesced from 480 → 720 (one row forward)')
      t.eq(root.ppq, 0, 'root unmoved')

      local kid
      for _, n in ipairs(h.fm:dump().notes) do
        if n.parentUuid == 1 then kid = n end
      end
      t.truthy(kid, 'kid re-emitted on rebuild')
      t.eq(kid.ppq, 720, 'kid resolves at row 3 (root.ppq + 720)')
    end,
  },

  --------------------------------------------------------------------
  -- Selection contains a root AND its aliased child: localRoots
  -- filters the child out so the root's direct stamp doesn't compound
  -- with a spec append on rebuild. Only the root moves; spec ppqL
  -- stays untouched, kid follows the root.
  --------------------------------------------------------------------
  {
    name = 'multi position nudge selection root+child: child filtered, spec.ppqL untouched, kid follows root',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          children = {
            { xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local noteCol
      for ci, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then noteCol = ci; break end
      end
      h.ec:setSelection{ row1 = 0, row2 = 2, col1 = noteCol, col2 = noteCol,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('nudgeForward')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(root.ppq, 240, 'root stamped one row forward')
      t.deepEq(root.children[1].xform.ppqL, {{'add', 480}},
               'spec ppqL unchanged — child filtered, no second [add δ] appended')

      local kid
      for _, n in ipairs(h.fm:dump().notes) do
        if n.parentUuid == 1 then kid = n end
      end
      t.truthy(kid, 'kid still present')
      t.eq(kid.ppq, 720, 'kid follows root via unchanged xform (240 + 480)')
    end,
  },

  --------------------------------------------------------------------
  -- A nudge after a `{add, {rand,...}}` appends fresh; rand entry intact
  --------------------------------------------------------------------
  {
    name = 'nudge after rand-arg op appends fresh, does not mutate rand entry',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1',
              xform = { ppqL  = {{'add', 240}},
                        pitch = {{'add', {'rand', 0, 1}}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)
      h.cmgr:invoke('nudgeFineUp')

      local root  = rootByUuid(h.fm:dump().notes, 1)
      local pitch = root.children[1].xform.pitch
      t.eq(#pitch, 2, 'op list grew to 2 entries')
      t.deepEq(pitch[1], {'add', {'rand', 0, 1}}, 'rand entry intact')
      t.deepEq(pitch[2], {'add', 1},              'fresh add appended')
    end,
  },
}
