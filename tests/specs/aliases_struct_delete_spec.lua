-- Phase 5.2: structural delete on aliased / aliasing events.
-- See design/aliases.md §"Structural — alters the spec tree" and
-- §"Cascade-delete vs sever-and-promote". The spec node is removed;
-- its direct children are promoted in place to new roots (sever-style).
-- Suppressed branches are dropped.

local t = require('support')

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

local function byParent(list, uuid)
  local out = {}
  for _, e in ipairs(list) do
    if e.parentUuid == uuid then out[#out + 1] = e end
  end
  return out
end

local function freeRoots(list)
  local out = {}
  for _, e in ipairs(list) do
    if not e.parentUuid then out[#out + 1] = e end
  end
  return out
end

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

return {
  --------------------------------------------------------------------
  -- Leaf alias: spec node removed, no children to promote
  --------------------------------------------------------------------
  {
    name = 'leaf alias: spec node removed, materialisation gone after rebuild',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      local kid = byParent(h.fm:dump().notes, 1)[1]
      t.truthy(kid)

      t.truthy(h.tm:deleteAliased(kid))
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'only the original root survives')
      local root = rootByUuid(notes, 1)
      t.deepEq(root.aliases, {}, 'spec tree empty')
    end,
  },

  --------------------------------------------------------------------
  -- Mid alias with children: each child promoted in place
  --------------------------------------------------------------------
  {
    name = 'mid alias: direct children promoted; descendants resolved unchanged',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 200}} }, children = {
              { id = '1', xform = { ppqL = {{'add',  50}} }, children = {} },
              { id = '2', xform = { ppqL = {{'add', 100}} }, children = {
                { id = '1', xform = { ppqL = {{'add', 60}}, vel = {{'add', 5}} },
                  children = {} },
              }},
            }},
          },
        } } },
      }
      local pre = h.fm:dump().notes
      local mid, ch1, ch2
      for _, k in ipairs(byParent(pre, 1)) do
        local idx = h.tm:specPathOf(k)
        local key = idx and table.concat(idx, '.') or nil
        if     key == '1'   then mid = k
        elseif key == '1.1' then ch1 = k
        elseif key == '1.2' then ch2 = k
        end
      end
      t.truthy(mid); t.truthy(ch1); t.truthy(ch2)
      t.eq(ch1.ppq, 250); t.eq(ch2.ppq, 300)

      t.truthy(h.tm:deleteAliased(mid))
      h.tm:flush()

      local notes  = h.fm:dump().notes
      local origin = rootByUuid(notes, 1)
      t.deepEq(origin.aliases, {}, 'mid spec node and its subtree gone from old root')

      local roots = freeRoots(notes)
      t.eq(#roots, 3, 'old root + two promoted')

      local promoted = {}
      for _, r in ipairs(roots) do
        if r.uuid ~= 1 then promoted[r.ppq] = r end
      end
      t.truthy(promoted[250], 'first promoted root keeps its resolved ppq')
      t.truthy(promoted[300], 'second promoted root keeps its resolved ppq')
      t.deepEq(promoted[250].aliases, {}, 'leaf child carries empty subtree')
      t.eq(#promoted[300].aliases, 1, 'second carries its one grandchild spec')

      local gks = byParent(notes, promoted[300].uuid)
      t.eq(#gks, 1)
      t.eq(gks[1].ppq, 360, 'grandchild keeps its 300+60 resolved ppq')
      t.eq(gks[1].vel, 105, 'grandchild vel composes against new root vel')
      t.deepEq(h.tm:specPathOf(gks[1]), {1}, 'grandchild specPath now relative to new root')
    end,
  },

  --------------------------------------------------------------------
  -- Top-level alias with siblings: siblings stay
  --------------------------------------------------------------------
  {
    name = 'top-level alias deleted; sibling alias survives untouched',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
            { id = '2', xform = { ppqL = {{'add', 960}} }, children = {} },
          },
        } } },
      }
      local target
      for _, k in ipairs(byParent(h.fm:dump().notes, 1)) do
        local idx = h.tm:specPathOf(k)
        if idx and table.concat(idx, '.') == '1' then target = k end
      end
      t.truthy(h.tm:deleteAliased(target))
      h.tm:flush()

      local notes = h.fm:dump().notes
      local root  = rootByUuid(notes, 1)
      t.eq(#root.aliases, 1)
      t.deepEq(root.aliases[1].xform.ppqL, {{'add', 960}}, 'sibling preserved')

      local survivors = byParent(notes, 1)
      t.eq(#survivors, 1)
      t.eq(survivors[1].ppq, 960)
    end,
  },

  --------------------------------------------------------------------
  -- Delete on a root with descendants: top-level children promoted,
  -- root itself deleted
  --------------------------------------------------------------------
  {
    name = 'delete on root: top-level children promoted, root removed',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {
              { id = '1', xform = { ppqL = {{'add', 100}}, vel = {{'add', 7}} },
                children = {} },
            }},
            { id = '2', xform = { ppqL = {{'add', 960}}, pitch = {{'add', 2}} },
              children = {} },
          },
        } } },
      }
      local root = rootByUuid(h.fm:dump().notes, 1)
      t.truthy(root)

      t.truthy(h.tm:deleteAliased(root))
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.falsy(rootByUuid(notes, 1), 'old root deleted')

      local roots = freeRoots(notes)
      t.eq(#roots, 2, 'two promoted roots remain')

      local byPpq = {}
      for _, r in ipairs(roots) do byPpq[r.ppq] = r end
      t.truthy(byPpq[480]); t.truthy(byPpq[960])
      t.eq(byPpq[480].pitch, 60, 'first promoted keeps resolved pitch')
      t.eq(byPpq[960].pitch, 62, 'second promoted keeps composed pitch')

      local gks = byParent(notes, byPpq[480].uuid)
      t.eq(#gks, 1)
      t.eq(gks[1].ppq, 580, 'grandchild keeps its 480+100 resolved ppq')
      t.eq(gks[1].vel, 107, 'grandchild vel composes against promoted root')
    end,
  },

  --------------------------------------------------------------------
  -- Plain event: no-op so caller can fall back to ordinary delete
  --------------------------------------------------------------------
  {
    name = 'plain unaliased event: returns false, no mutations',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, uuid = 1 },
        } },
      }
      local plain = h.fm:dump().notes[1]
      t.falsy(h.tm:deleteAliased(plain))
      t.eq(#h.fm:dump().notes, 1)
    end,
  },

  --------------------------------------------------------------------
  -- Three-level subtree-delete with mixed materialised / suppressed
  -- direct children. L1 has two children: A (suppressed by collision
  -- with L1's own emit) and B (uncolliding, materialised). Under the
  -- suppressed A sits a grandchild X that resolves to its own free
  -- slot and *does* materialise. Deleting L1 must:
  --   - promote B (materialised direct child) to a new root
  --   - drop A silently (no materialisation to promote)
  --   - sweep X's stale emit on the rebuild that follows; X carried
  --     parentUuid=root.uuid but its spec line vanished with L1's pluck
  --------------------------------------------------------------------
  {
    name = 'three-level delete: suppressed mid drops; its materialised grandchild is swept',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliases = {
            { xform = { ppqL = {{'add', 480}} }, children = {
              { xform = {}, children = {
                { xform = { ppqL = {{'add', 240}} }, children = {} },
              }},
              { xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
                children = {} },
            }},
          },
        } } },
      }

      -- Pre-state: L1 @480, A suppressed (collides with L1 @480),
      -- A.X @720 pitch=60, B @720 pitch=61.
      local pre = h.fm:dump().notes
      local l1, ax, b
      for _, k in ipairs(byParent(pre, 1)) do
        if     k.ppq == 480                  then l1 = k
        elseif k.ppq == 720 and k.pitch == 60 then ax = k
        elseif k.ppq == 720 and k.pitch == 61 then b  = k
        end
      end
      t.truthy(l1, 'L1 materialised at 480')
      t.truthy(ax, 'A.X materialised at 720/60 under suppressed A')
      t.truthy(b,  'B materialised at 720/61')

      t.truthy(h.tm:deleteAliased(l1))
      h.tm:flush()

      local notes  = h.fm:dump().notes
      local origin = rootByUuid(notes, 1)
      t.deepEq(origin.aliases, {}, 'L1 plucked from root; whole subtree gone')

      local roots = freeRoots(notes)
      t.eq(#roots, 2, 'old root + one promoted (B); suppressed A and its kid X dropped')

      local promoted
      for _, r in ipairs(roots) do
        if r.uuid ~= 1 then promoted = r end
      end
      t.truthy(promoted)
      t.eq(promoted.ppq,   720, 'B keeps its resolved ppq')
      t.eq(promoted.pitch, 61,  'B keeps its resolved pitch')
      t.deepEq(promoted.aliases, {}, 'B carries no subtree')

      -- No survivor with parentUuid=1 remains.
      t.eq(#byParent(notes, 1), 0, 'all aliased kids of old root gone')
    end,
  },

  --------------------------------------------------------------------
  -- Suppressed child: no materialisation to promote, subtree dropped
  --------------------------------------------------------------------
  {
    name = 'suppressed child branch is dropped on structural delete',
    run = function(harness)
      -- Two roots at the same slot: second root's emit collides with
      -- root1's note. Root2's spec child '1' would land at root2's slot
      -- shifted by +0 — collides with root2 itself? No: root2 is not in
      -- claims as alias-emit, only as a real note. The walker's claim
      -- map seeds from non-aliased notes. Set up a clearer collision:
      -- root1 emits child A at ppq=480; root2 (ppq=480) blocks A.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100,
            uuid = 1, aliasCtr = 3,
            aliases = {
              { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
              { id = '2', xform = { ppqL = {{'add', 720}} }, children = {} },
            } },
          { ppq = 480, endppq = 720, chan = 1, pitch = 60, vel = 100,
            uuid = 2 },
        } },
      }
      -- Confirm the '1' alias is suppressed and '2' emits.
      local survived = byParent(h.fm:dump().notes, 1)
      local paths = {}
      for _, k in ipairs(survived) do
        local idx = h.tm:specPathOf(k)
        if idx then paths[table.concat(idx, '.')] = true end
      end
      t.falsy(paths['1'], "suppressed child has no materialisation")
      t.truthy(paths['2'], "uncolliding child emits")

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.truthy(h.tm:deleteAliased(root))
      h.tm:flush()

      -- Root 1 deleted; the surviving '2' branch promoted; the suppressed
      -- '1' branch is dropped (no surfacing of previously-invisible state).
      local notes = h.fm:dump().notes
      t.falsy(rootByUuid(notes, 1))
      t.truthy(rootByUuid(notes, 2), 'unrelated root2 untouched')
      local roots = freeRoots(notes)
      t.eq(#roots, 2, 'root2 + the one promoted alias; nothing for suppressed')
    end,
  },
}
