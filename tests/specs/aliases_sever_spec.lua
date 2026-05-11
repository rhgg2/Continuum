-- Phase 5.1: sever-and-promote primitive.
-- See design/aliases.md §Severance. The materialised event is promoted
-- in place: its mm-uuid carries through as the new root's permanent id,
-- the plucked subtree's children become the new root's `aliases`, and
-- the rebuild walker stops sweeping it once parentUuid is gone.

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

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

return {
  --------------------------------------------------------------------
  -- Single-level: pluck, promote, materialisation metadata cleared
  --------------------------------------------------------------------
  {
    name = 'severs a single-level alias; promoted note keeps its resolved fields',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 480}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }
      local kid = byParent(h.fm:dump().notes, 1)[1]
      t.truthy(kid, 'walker emitted the materialisation')
      t.eq(kid.ppq, 480); t.eq(kid.pitch, 61)

      t.truthy(h.tm:sever(kid))
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'two plain roots, no surviving materialisations')

      local oldRoot = rootByUuid(notes, 1)
      t.truthy(oldRoot)
      t.deepEq(oldRoot.aliases, {}, 'old root spec tree empty')

      local promoted
      for _, n in ipairs(notes) do
        if n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted, 'promoted root present under a different uuid')
      t.eq(promoted.parentUuid, nil, 'parentUuid stripped')
      t.eq(promoted.specPath,   nil, 'specPath stripped')
      t.eq(promoted.ppq,    480, 'resolved ppq preserved')
      t.eq(promoted.pitch,  61,  'resolved pitch preserved')
      t.deepEq(promoted.aliases, {}, 'no inherited subtree')
    end,
  },

  --------------------------------------------------------------------
  -- Sibling left intact when one of two top-level aliases is severed
  --------------------------------------------------------------------
  {
    name = 'sibling alias survives when its peer is severed',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 480}} },  children = {} },
            { id = '2', xform = { ppqL = {{'add', 960}} },  children = {} },
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 2)

      local target
      for _, k in ipairs(kids) do if k.specPath == '1' then target = k end end
      t.truthy(h.tm:sever(target))
      h.tm:flush()

      local notes = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 1, 'one spec node remains')
      t.eq(oldRoot.aliases[1].id, '2', 'the right one (sibling) remains')

      local survivors = byParent(notes, 1)
      t.eq(#survivors, 1, 'sibling materialisation re-emitted')
      t.eq(survivors[1].specPath, '2')
      t.eq(survivors[1].ppq, 960)
    end,
  },

  --------------------------------------------------------------------
  -- Subtree follows the promoted root; descendants resolve unchanged
  --------------------------------------------------------------------
  {
    name = 'sever in the middle: subtree follows; descendant resolved fields preserved',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 200}} }, children = {
              { id = '1', xform = { ppqL = {{'mul', 2}} }, children = {
                { id = '1', xform = { ppqL = {{'add', 1}}, vel = {{'add', 10}} },
                  children = {} },
              }},
            }},
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 3)
      local pre = {}
      for _, k in ipairs(kids) do pre[k.specPath] = k.ppq end
      t.eq(pre['1'    ], 200)
      t.eq(pre['1.1'  ], 400)
      t.eq(pre['1.1.1'], 401)

      local mid
      for _, k in ipairs(kids) do if k.specPath == '1.1' then mid = k end end
      t.truthy(h.tm:sever(mid))
      h.tm:flush()

      local notes = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      -- old root's '1' node had only one child, '1.1', which we plucked.
      t.eq(#oldRoot.aliases, 1)
      t.eq(oldRoot.aliases[1].id, '1')
      t.eq(#oldRoot.aliases[1].children, 0, 'plucked subtree gone from old root')

      -- The promoted root carries the plucked node's children as its aliases.
      -- Its baked-in ppq is mid's resolved value (400).
      local promoted
      for _, n in ipairs(notes) do
        if n.uuid ~= 1 and not n.parentUuid then promoted = n end
      end
      t.truthy(promoted)
      t.eq(promoted.ppq, 400, 'promoted root keeps mid resolved ppq')
      t.eq(#promoted.aliases, 1, 'plucked child carried over')

      -- Grandchild re-emits under the new root. Its resolved ppq is the
      -- new root's 400 plus its xform's ppqL +1 = 401, identical to before.
      -- vel composes: root vel 100 + 10 = 110 (mid's vel xform was empty,
      -- so the grandchild's spec node still adds +10 to root vel).
      local newKids = byParent(notes, promoted.uuid)
      t.eq(#newKids, 1)
      t.eq(newKids[1].ppq, 401, 'grandchild ppq unchanged by sever')
      t.eq(newKids[1].vel, 110, 'grandchild vel unchanged by sever')
      t.eq(newKids[1].specPath, '1', 'grandchild specPath now relative to new root')
    end,
  },

  --------------------------------------------------------------------
  -- aliasCtr is set past the highest id anywhere in the plucked subtree
  --------------------------------------------------------------------
  {
    name = 'aliasCtr on promoted root skips ids surviving in the subtree',
    run = function(harness)
      -- Plucked subtree has children with ids '3' and '5', plus a deeper
      -- '7' under '3'. After sever, aliasCtr on the new root must be ≥ 8
      -- so a fresh allocation does not collide with surviving ids.
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 9,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 100}} }, children = {
              { id = '3', xform = {}, children = {
                { id = '7', xform = {}, children = {} },
              }},
              { id = '5', xform = {}, children = {} },
            }},
          },
        } } },
      }
      local mid
      for _, k in ipairs(byParent(h.fm:dump().notes, 1)) do
        if k.specPath == '1' then mid = k end
      end
      t.truthy(h.tm:sever(mid))
      h.tm:flush()

      local promoted
      for _, n in ipairs(h.fm:dump().notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted)
      local newId = aliases.allocId(promoted)
      t.eq(util.fromBase36(newId), 8, 'next id is past the highest surviving id (7)')
    end,
  },

  --------------------------------------------------------------------
  -- severBatch: two children of the same root in one call. A naïve
  -- per-event sever loop loses the second pluck because each tm:sever
  -- writes the whole root.aliases back from its own clone.
  --------------------------------------------------------------------
  {
    name = 'severBatch on two children of one root: both spec nodes plucked',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
            { id = '2', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 2)
      h.tm:severBatch(kids)
      h.tm:flush()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.deepEq(oldRoot.aliases, {}, 'both spec nodes plucked in one batch')

      local roots = {}
      for _, n in ipairs(notes) do
        if not n.parentUuid then roots[n.uuid] = n end
      end
      t.eq(roots[1] and 1 or 0, 1, 'old root survives')
      local promotedCount = 0
      for u, _ in pairs(roots) do if u ~= 1 then promotedCount = promotedCount + 1 end end
      t.eq(promotedCount, 2, 'both materialisations promoted')
    end,
  },

  --------------------------------------------------------------------
  -- Plain event: no-op
  --------------------------------------------------------------------
  {
    name = 'sever on a plain (non-aliased) event is a no-op',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, uuid = 1 },
        } },
      }
      local plain = h.fm:dump().notes[1]
      t.falsy(h.tm:sever(plain))
    end,
  },
}
