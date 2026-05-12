-- Phase 1 pin-tests for aliases.lua: applyXform / appendOp / spec-tree
-- navigation. All pure; no REAPER, no mm.

local t = require('support')
require('util')
require('aliases')

local seededRng = aliases.makeRng

-- Reference LCG used during phase 1 development. Pinned here so a
-- regression in aliases.makeRng surfaces as sequence drift.
local function refRng(seed)
  local state = seed
  return function(lo, hi)
    state = (state * 1103515245 + 12345) % 2147483648
    return lo + (state / 2147483648) * (hi - lo)
  end
end

return {
  --------------------------------------------------------------------
  -- applyOp / single-op application
  --------------------------------------------------------------------
  {
    name = 'applyOp: add literal',
    run = function() t.eq(aliases.applyOp(100, {'add', 4}), 104) end,
  },
  {
    name = 'applyOp: mul literal',
    run = function() t.eq(aliases.applyOp(100, {'mul', 0.5}), 50) end,
  },
  {
    name = 'applyOp: rand arg invokes rng, not math.random',
    run = function()
      local rng = function(lo, hi) t.eq(lo, -3); t.eq(hi, 5); return 2 end
      t.eq(aliases.applyOp(100, {'add', {'rand', -3, 5}}, rng), 102)
    end,
  },
  {
    name = 'applyOp: rand without rng raises',
    run = function()
      local ok = pcall(function() aliases.applyOp(0, {'add', {'rand', 0, 1}}) end)
      t.falsy(ok, 'expected error when rng missing')
    end,
  },

  --------------------------------------------------------------------
  -- applyXform / left-to-right
  --------------------------------------------------------------------
  {
    name = 'applyXform: empty xform is identity',
    run = function()
      local out = aliases.applyXform({ ppqL = 10, vel = 64 }, {}, 'note')
      t.deepEq(out, { ppqL = 10, vel = 64 })
    end,
  },
  {
    name = 'applyXform: (((x+4)*2)+1) left-to-right',
    run = function()
      -- 10 → +4 → 14 → *2 → 28 → +1 → 29
      local out = aliases.applyXform(
        { ppqL = 10 },
        { ppqL = {{'add',4},{'mul',2},{'add',1}} },
        'note')
      t.eq(out.ppqL, 29)
    end,
  },
  {
    name = 'applyXform: reversed list — order matters',
    run = function()
      local out = aliases.applyXform(
        { ppqL = 10 },
        { ppqL = {{'add',1},{'mul',2},{'add',4}} },
        'note')
      t.eq(out.ppqL, 26)
    end,
  },
  {
    name = 'applyXform: cross-type fail-closed (pitch on cc skipped)',
    run = function()
      local out = aliases.applyXform(
        { ppqL = 10, val = 64 },
        { pitch = {{'add',5}}, val = {{'add',3}} },
        'cc')
      t.deepEq(out, { ppqL = 10, val = 67 })
    end,
  },
  {
    name = 'applyXform: multi-field independence',
    run = function()
      local out = aliases.applyXform(
        { ppqL = 10, vel = 64, pitch = 60 },
        { ppqL = {{'add',2}}, vel = {{'mul',2}} },
        'note')
      t.deepEq(out, { ppqL = 12, vel = 128, pitch = 60 })
    end,
  },
  {
    name = 'applyXform: missing resolved field raises',
    run = function()
      local ok = pcall(function()
        aliases.applyXform({ ppqL = 10 }, { vel = {{'add',1}} }, 'note')
      end)
      t.falsy(ok, 'expected error when field missing from resolved')
    end,
  },
  {
    name = 'applyXform: purity — inputs unchanged',
    run = function()
      local resolved = { ppqL = 10 }
      local xform    = { ppqL = {{'add',4}} }
      aliases.applyXform(resolved, xform, 'note')
      t.deepEq(resolved, { ppqL = 10 })
      t.deepEq(xform,    { ppqL = {{'add',4}} })
    end,
  },

  --------------------------------------------------------------------
  -- RNG injection / determinism / distribution
  --------------------------------------------------------------------
  {
    name = 'rand: seeded RNG produces a deterministic sequence',
    run = function()
      local x  = { ppqL = {{'add', {'rand', -3, 5}}} }
      local r1, r2 = seededRng(42), seededRng(42)
      local a = aliases.applyXform({ ppqL = 0 }, x, 'note', r1).ppqL
      local b = aliases.applyXform({ ppqL = 0 }, x, 'note', r2).ppqL
      t.eq(a, b)
    end,
  },
  {
    name = 'rand: stays within bounds over N draws',
    run = function()
      local x = { ppqL = {{'add', {'rand', -3, 5}}} }
      local rng = seededRng(7)
      local lo, hi, sum = math.huge, -math.huge, 0
      local N = 1000
      for _ = 1, N do
        local v = aliases.applyXform({ ppqL = 0 }, x, 'note', rng).ppqL
        if v < lo then lo = v end
        if v > hi then hi = v end
        sum = sum + v
      end
      t.truthy(lo >= -3, 'lo bound')
      t.truthy(hi <= 5,  'hi bound')
      local mean = sum / N
      t.truthy(math.abs(mean - 1) < 0.5, 'mean near 1: ' .. mean)
    end,
  },

  {
    name = 'makeRng: matches reference LCG sequence',
    run = function()
      local a, b = aliases.makeRng(12345), refRng(12345)
      for _ = 1, 32 do t.eq(a(-7, 11), b(-7, 11)) end
    end,
  },

  --------------------------------------------------------------------
  -- Cross-node concatenation
  --------------------------------------------------------------------
  {
    name = 'concatenated lists resolve k2*(k1*(x+a1)) + a2',
    run = function()
      local a1, k1, k2, a2, x = 4, 2, 3, 5, 10
      local parent = { ppqL = {{'add',a1},{'mul',k1}} }
      local child  = { ppqL = {{'mul',k2},{'add',a2}} }
      -- Concatenation: append child ops to parent's list.
      local concat = { ppqL = {} }
      for _, op in ipairs(parent.ppqL) do concat.ppqL[#concat.ppqL+1] = op end
      for _, op in ipairs(child.ppqL)  do concat.ppqL[#concat.ppqL+1] = op end
      local out = aliases.applyXform({ ppqL = x }, concat, 'note')
      t.eq(out.ppqL, k2 * (k1 * (x + a1)) + a2)
    end,
  },

  --------------------------------------------------------------------
  -- appendOp / coalescence
  --------------------------------------------------------------------
  {
    name = 'appendOp: add+add coalesces literals',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'add', 4})
      x = aliases.appendOp(x, 'ppqL', {'add', 5})
      t.deepEq(x.ppqL, {{'add', 9}})
    end,
  },
  {
    name = 'appendOp: mul+mul coalesces literals',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'mul', 2})
      x = aliases.appendOp(x, 'ppqL', {'mul', 0.5})
      t.deepEq(x.ppqL, {{'mul', 1}})
    end,
  },
  {
    name = 'appendOp: different opcodes do not merge',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'add', 4})
      x = aliases.appendOp(x, 'ppqL', {'mul', 2})
      t.deepEq(x.ppqL, {{'add', 4}, {'mul', 2}})
    end,
  },
  {
    name = 'appendOp: trailing non-literal blocks merge (rand at tail)',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'add', {'rand', -1, 1}})
      x = aliases.appendOp(x, 'ppqL', {'add', 2})
      t.deepEq(x.ppqL, {{'add', {'rand', -1, 1}}, {'add', 2}})
    end,
  },
  {
    name = 'appendOp: incoming non-literal blocks merge',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'add', 4})
      x = aliases.appendOp(x, 'ppqL', {'add', {'rand', -1, 1}})
      t.deepEq(x.ppqL, {{'add', 4}, {'add', {'rand', -1, 1}}})
    end,
  },
  {
    name = 'appendOp: purity — input xform unchanged',
    run = function()
      local x0 = { ppqL = {{'add', 4}} }
      aliases.appendOp(x0, 'ppqL', {'add', 5})
      t.deepEq(x0, { ppqL = {{'add', 4}} })
    end,
  },
  {
    name = 'appendOp: into a fresh field creates the list',
    run = function()
      local x = aliases.appendOp({ ppqL = {{'add', 1}} }, 'vel', {'add', 7})
      t.deepEq(x.vel, {{'add', 7}})
      t.deepEq(x.ppqL, {{'add', 1}})
    end,
  },

  --------------------------------------------------------------------
  -- snap opcode
  --------------------------------------------------------------------
  {
    name = 'applyOp: snap rounds running value to nearest multiple of step',
    run = function()
      t.eq(aliases.applyOp(250, {'snap', 60}), 240)   -- 250/60 = 4.16 → 4
      t.eq(aliases.applyOp(290, {'snap', 60}), 300)   -- 290/60 = 4.83 → 5
      t.eq(aliases.applyOp(240, {'snap', 60}), 240)
    end,
  },
  {
    name = 'applyOp: snap is idempotent at the grid step',
    run = function()
      local once  = aliases.applyOp(250, {'snap', 60})
      local twice = aliases.applyOp(once, {'snap', 60})
      t.eq(once, twice)
    end,
  },
  {
    name = 'applyXform: snap composes through ppqL on a note',
    run = function()
      local out = aliases.applyXform(
        { ppqL = 0 },
        { ppqL = {{'add', 250}, {'snap', 60}} },
        'note')
      t.eq(out.ppqL, 240)
    end,
  },
  {
    name = 'appendOp: two commensurate snaps coalesce to the coarser step',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'snap', 60})
      x = aliases.appendOp(x, 'ppqL', {'snap', 120})
      t.deepEq(x.ppqL, {{'snap', 120}})
    end,
  },
  {
    name = 'appendOp: snaps merge regardless of which is appended first',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'snap', 120})
      x = aliases.appendOp(x, 'ppqL', {'snap', 60})
      t.deepEq(x.ppqL, {{'snap', 120}}, 'coarser still wins')
    end,
  },
  {
    name = 'appendOp: non-commensurate snaps stay as two ops',
    run = function()
      -- Snap-7 then snap-5 is not equivalent to any single snap; keep both.
      local x = aliases.appendOp({}, 'ppqL', {'snap', 7})
      x = aliases.appendOp(x, 'ppqL', {'snap', 5})
      t.deepEq(x.ppqL, {{'snap', 7}, {'snap', 5}})
    end,
  },
  {
    name = 'appendOp: snap then add does not coalesce',
    run = function()
      local x = aliases.appendOp({}, 'ppqL', {'snap', 60})
      x = aliases.appendOp(x, 'ppqL', {'add', 4})
      t.deepEq(x.ppqL, {{'snap', 60}, {'add', 4}})
    end,
  },
  {
    name = 'applyXform: sequential non-commensurate snaps apply in order',
    run = function()
      -- 7 → snap(7) → 7 → snap(5) → 5. (LCM-of-steps interpretation
      -- would say snap-to-35 of 7 = 0; sequential application differs.)
      local out = aliases.applyXform(
        { ppqL = 7 },
        { ppqL = {{'snap', 7}, {'snap', 5}} },
        'note')
      t.eq(out.ppqL, 5)
    end,
  },

  --------------------------------------------------------------------
  -- Spec-tree navigation
  --------------------------------------------------------------------
  {
    name = 'find: locates a 3-deep node by integer-array path',
    run = function()
      local target = { xform = { ppqL = {{'add',9}} }, children = {} }
      local root = {
        aliases = {
          { xform = {}, children = {
            { xform = { ppqL = {{'add',1}} }, children = { target } },
          }},
        },
      }
      t.eq(aliases.find(root, {1,1,1}), target)
    end,
  },
  {
    name = 'find: missing path returns nil',
    run = function()
      local root = { aliases = { { xform={}, children={} } } }
      t.eq(aliases.find(root, {1,7}), nil)
      t.eq(aliases.find(root, {9}),   nil)
    end,
  },
  {
    name = 'parentOf: top-level returns root.aliases',
    run = function()
      local root = { aliases = { { xform={}, children={} } } }
      local list, i = aliases.parentOf(root, {1})
      t.eq(list, root.aliases)
      t.eq(i, 1)
    end,
  },
  {
    name = 'parentOf: nested returns intermediate children list',
    run = function()
      local inner = { xform={}, children={} }
      local root = { aliases = {
        { xform={}, children = { inner } },
      }}
      local list, i = aliases.parentOf(root, {1,1})
      t.eq(list, root.aliases[1].children)
      t.eq(i, 1)
    end,
  },
  {
    name = 'pluckSubtree: removes from parent, leaves siblings',
    run = function()
      local a = { xform={}, children={} }
      local b = { xform={ ppqL={{'add',9}} }, children={ { xform={}, children={} } } }
      local c = { xform={}, children={} }
      local root = { aliases = { a, b, c } }
      local got = aliases.pluckSubtree(root, {2})
      t.eq(got, b)
      t.eq(#got.children, 1)            -- descendants survive
      t.eq(#root.aliases, 2)
      t.eq(root.aliases[1], a)
      t.eq(root.aliases[2], c)
    end,
  },
  {
    name = 'pluckSubtree: missing path returns nil, tree unchanged',
    run = function()
      local root = { aliases = { { xform={}, children={} } } }
      t.eq(aliases.pluckSubtree(root, {9}), nil)
      t.eq(#root.aliases, 1)
    end,
  },

  --------------------------------------------------------------------
  -- localRoots: filter a selection to its local roots
  --------------------------------------------------------------------
  {
    name = 'localRoots: plain events all survive',
    run = function()
      local a, b = { uuid = 1 }, { uuid = 2 }
      t.deepEq(aliases.localRoots{ a, b }, { a, b })
    end,
  },
  {
    name = 'localRoots: child whose parent is in the set is filtered',
    run = function()
      local root = { uuid = 1 }
      local kid  = { uuid = 2, parentUuid = 1 }
      t.deepEq(aliases.localRoots{ root, kid }, { root })
    end,
  },
  {
    name = 'localRoots: child whose parent is absent survives',
    run = function()
      local kid = { uuid = 2, parentUuid = 99 }
      t.deepEq(aliases.localRoots{ kid }, { kid })
    end,
  },
  {
    name = 'localRoots: mixed siblings — keep root and orphan kid, drop in-set kid',
    run = function()
      local root  = { uuid = 1 }
      local kid1  = { uuid = 2, parentUuid = 1 }   -- drop: parent in set
      local kid2  = { uuid = 3, parentUuid = 99 }  -- keep: parent absent
      local plain = { uuid = 4 }
      t.deepEq(aliases.localRoots{ root, kid1, kid2, plain },
               { root, kid2, plain })
    end,
  },
  {
    name = 'localRoots: preserves input order',
    run = function()
      local a = { uuid = 10 }
      local b = { uuid = 11, parentUuid = 10 }
      local c = { uuid = 12 }
      t.deepEq(aliases.localRoots{ c, a, b }, { c, a })
    end,
  },

  --------------------------------------------------------------------
  -- Round-trip
  --------------------------------------------------------------------
  {
    name = 'util.serialise round-trip on nested spec tree',
    run = function()
      local tree = {
        aliasCtr = 4,
        aliases = {
          { id='1', xform = { ppqL = {{'add',120}}, pitch = {{'add',7}} },
            children = {
              { id='1', xform = { ppqL = {{'add',240}} }, children = {} },
            }},
          { id='2', xform = { ppqL = {{'add',480}} }, children = {} },
          { id='3', xform = { vel  = {{'add',{'rand',-3,5}}} }, children = {} },
        },
      }
      local round = util.unserialise(util.serialise(tree))
      t.deepEq(round, tree)
    end,
  },
}
