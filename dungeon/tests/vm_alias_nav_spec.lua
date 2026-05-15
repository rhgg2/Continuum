-- vm-level alias dependency index (built in vm:rebuild's cells loop)
-- and the four alias-tree navigation commands.

local t = require('support')

-- rowPerBeat=1, resolution=240 → 240 ppq per row, so child at +240 ppq
-- lands on row 1.
local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, uuid = 1, ppqL = 0, endppqL = 240 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local function mkH(harness, children)
  local h = harness.mk{
    config = { track = { rowPerBeat = 1 } },
    seed   = { notes = { rootNote{ aliasCtr = 1 + #children, children = children } } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

local function findRoot(h)
  for _, n in ipairs(h.fm:dump().notes) do
    if n.uuid == 1 then return n end
  end
end

local function findChildBySpecPath(h, path)
  for _, n in ipairs(h.fm:dump().notes) do
    local idx = h.tm:specPathOf(n)
    if idx and table.concat(idx, '.') == path then return n end
  end
end

return {
  --------------------------------------------------------------------
  -- Empty index when nothing is aliased.
  --------------------------------------------------------------------
  {
    name = 'aliasIndex starts empty under aliasless seed',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, uuid = 7 } } },
      }
      h.vm:setGridSize(80, 40)
      local idx = h.vm:aliasIndex()
      t.deepEq(next(idx.byChildren), nil, 'byChildren has no entries')
      t.truthy(idx.byUuid[7], 'byUuid carries the lone seed event')
      t.eq(idx.byUuid[7].evt.pitch, 60)
    end,
  },

  --------------------------------------------------------------------
  -- byUuid resolves the root and every emitted child.
  --------------------------------------------------------------------
  {
    name = 'aliasIndex.byUuid resolves root + children',
    run = function(harness)
      local h = mkH(harness, {
        { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
        { id = '2', xform = { ppqL = {{'add', 480}} }, children = {} },
      })
      local idx = h.vm:aliasIndex()
      t.truthy(idx.byUuid[1], 'root in byUuid')
      local c1 = findChildBySpecPath(h, '1')
      local c2 = findChildBySpecPath(h, '2')
      t.truthy(c1 and idx.byUuid[c1.uuid], 'spec-1 child in byUuid')
      t.truthy(c2 and idx.byUuid[c2.uuid], 'spec-2 child in byUuid')
    end,
  },

  --------------------------------------------------------------------
  -- byParent[root.uuid] is sorted by (ppq, chan) ascending. Seed
  -- declares specs in reverse-ppq order to prove the sort runs.
  --------------------------------------------------------------------
  {
    name = 'aliasIndex.byParent sorted by ppq ascending',
    run = function(harness)
      local h = mkH(harness, {
        { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
        { id = '2', xform = { ppqL = {{'add', 240}} }, children = {} },
      })
      local idx = h.vm:aliasIndex()
      local list = idx.byChildren[1]
      t.eq(#list, 2)
      t.eq(list[1].ppq, 240, 'first sibling is the earlier child')
      t.eq(list[2].ppq, 480, 'second sibling is the later child')
    end,
  },

  --------------------------------------------------------------------
  -- aliasDown from the root cursor moves to the first child by grid
  -- order; aliasUp from a child moves back to the root.
  --------------------------------------------------------------------
  {
    name = 'aliasDown / aliasUp walk between root and first child',
    run = function(harness)
      local h = mkH(harness, {
        { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
      })
      h.ec:setPos(0, 1, 1)  -- root cell (row 0, chan-1 note col)
      local rootCol = h.ec:col()
      h.cmgr:invoke('aliasDown')
      t.eq(h.ec:row(), 1, 'aliasDown lands on the +1-row child')
      t.eq(h.ec:col(), rootCol, 'same column')

      h.cmgr:invoke('aliasUp')
      t.eq(h.ec:row(), 0, 'aliasUp returns to the root row')
      t.eq(h.ec:col(), rootCol)
    end,
  },

  --------------------------------------------------------------------
  -- aliasLeft / aliasRight walk siblings in grid order. From the
  -- second child, Left goes to the first; Right at the end is a no-op.
  --------------------------------------------------------------------
  {
    name = 'aliasLeft / aliasRight walk sibling list with no wrap',
    run = function(harness)
      local h = mkH(harness, {
        { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
        { id = '2', xform = { ppqL = {{'add', 480}} }, children = {} },
      })
      -- Seat the cursor on the second child (row 2).
      h.ec:setPos(2, 1, 1)
      h.cmgr:invoke('aliasLeft')
      t.eq(h.ec:row(), 1, 'aliasLeft moves to the earlier sibling')
      h.cmgr:invoke('aliasLeft')
      t.eq(h.ec:row(), 1, 'aliasLeft at first sibling is a no-op')
      h.cmgr:invoke('aliasRight')
      t.eq(h.ec:row(), 2, 'aliasRight moves to the later sibling')
      h.cmgr:invoke('aliasRight')
      t.eq(h.ec:row(), 2, 'aliasRight at last sibling is a no-op')
    end,
  },

  --------------------------------------------------------------------
  -- Up from a root is a no-op.
  --------------------------------------------------------------------
  {
    name = 'aliasUp from a root is a no-op',
    run = function(harness)
      local h = mkH(harness, {
        { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
      })
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('aliasUp')
      t.eq(h.ec:row(), 0, 'still on the root row')
    end,
  },

  --------------------------------------------------------------------
  -- Recursive: a grandchild's aliasUp walks one level at a time. Two
  -- ups from the grandchild row land on the root row.
  --------------------------------------------------------------------
  {
    name = 'aliasUp climbs one level per call in a recursive tree',
    run = function(harness)
      local h = mkH(harness, {
        { id = '1', xform = { ppqL = {{'add', 240}} }, children = {
          { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
        }},
      })
      -- Layout: root row 0, child '1' row 1, grandchild '1.1' row 2.
      h.ec:setPos(2, 1, 1)
      h.cmgr:invoke('aliasUp')
      t.eq(h.ec:row(), 1, 'first up lands on the intermediate child')
      h.cmgr:invoke('aliasUp')
      t.eq(h.ec:row(), 0, 'second up reaches the root')
      h.cmgr:invoke('aliasUp')
      t.eq(h.ec:row(), 0, 'third up is a no-op at the root')
    end,
  },
}
