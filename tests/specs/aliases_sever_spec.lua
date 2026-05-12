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
      for _, k in ipairs(kids) do
        if h.tm:specPathOf(k) and table.concat(h.tm:specPathOf(k), '.') == '1' then target = k end
      end
      t.truthy(h.tm:sever(target))
      h.tm:flush()

      local notes = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 1, 'one spec node remains')
      t.deepEq(oldRoot.aliases[1].xform.ppqL, {{'add', 960}}, 'the right one (sibling) remains')

      local survivors = byParent(notes, 1)
      t.eq(#survivors, 1, 'sibling materialisation re-emitted')
      t.deepEq(h.tm:specPathOf(survivors[1]), {1})
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
      for _, k in ipairs(kids) do
        local idx = h.tm:specPathOf(k)
        if idx then pre[table.concat(idx, '.')] = k.ppq end
      end
      t.eq(pre['1'    ], 200)
      t.eq(pre['1.1'  ], 400)
      t.eq(pre['1.1.1'], 401)

      local mid
      for _, k in ipairs(kids) do
        local idx = h.tm:specPathOf(k)
        if idx and table.concat(idx, '.') == '1.1' then mid = k end
      end
      t.truthy(h.tm:sever(mid))
      h.tm:flush()

      local notes = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      -- old root's '1' node had only one child, '1.1', which we plucked.
      t.eq(#oldRoot.aliases, 1)
      t.deepEq(oldRoot.aliases[1].xform.ppqL, {{'add', 200}}, 'remaining spec is the outer +200')
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
      t.deepEq(h.tm:specPathOf(newKids[1]), {1}, 'grandchild specPath now relative to new root')
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
  -- Non-monotonic severBatch on a 4-sibling parent. Targets are A and
  -- C, at positions 1 and 3 of [A,B,C,D]. Under index-based pluck the
  -- first pluck shifts C from index 3 to index 2; a second pluck of
  -- index 3 would hit D, leaving C in place. Identity-pluck does not
  -- care — table references survive list mutation.
  --------------------------------------------------------------------
  {
    name = 'severBatch on non-adjacent siblings of one parent: identity-pluck preserves the right survivors',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliases  = {
            { xform = { ppqL = {{'add', 240}} }, children = {} },
            { xform = { ppqL = {{'add', 480}} }, children = {} },
            { xform = { ppqL = {{'add', 720}} }, children = {} },
            { xform = { ppqL = {{'add', 960}} }, children = {} },
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 4)

      local a, c
      for _, k in ipairs(kids) do
        if k.ppq == 240 then a = k
        elseif k.ppq == 720 then c = k
        end
      end
      t.truthy(a); t.truthy(c)

      h.tm:severBatch{ a, c }
      h.tm:flush()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 2, 'two spec nodes remain')
      t.deepEq(oldRoot.aliases[1].xform.ppqL, {{'add', 480}}, 'B survives at slot 1')
      t.deepEq(oldRoot.aliases[2].xform.ppqL, {{'add', 960}}, 'D survives at slot 2')

      local survivors = byParent(notes, 1)
      t.eq(#survivors, 2, 'two aliased kids re-emit')
      local byPpq = {}
      for _, k in ipairs(survivors) do byPpq[k.ppq] = true end
      t.truthy(byPpq[480], 'B re-emits unchanged')
      t.truthy(byPpq[960], 'D re-emits unchanged')

      local promoted = {}
      for _, n in ipairs(notes) do
        if n.uuid ~= 1 and not n.parentUuid then promoted[n.ppq] = n end
      end
      t.truthy(promoted[240], 'A promoted')
      t.truthy(promoted[720], 'C promoted')
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
