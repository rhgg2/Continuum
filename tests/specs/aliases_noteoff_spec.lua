-- Phase 5.4: noteOff on an aliased child re-relativises tail-edits
-- through `durL` and routes the zero-duration branch through
-- deleteAliased so descendants promote in place.

local t = require('support')

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

local function aliasKid(notes, uuid)
  for _, n in ipairs(notes) do
    if n.parentUuid == uuid then return n end
  end
end

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 1, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

-- Locate the col carrying the alias-child uuid at `row`. Distinct pitch
-- on the alias keeps the lane allocator from interleaving plain root and
-- alias inside the same col.events list — simpler to read.
local function colAtRow(grid, row, parentUuid)
  for i, c in ipairs(grid.cols) do
    if c.type == 'note' and c.cells and c.cells[row]
       and c.cells[row].parentUuid == parentUuid then
      return i, c, c.cells[row]
    end
  end
end

local CFG = { take = { rowPerBeat = 1, currentOctave = 4, noteLayout = 'qwerty' } }

return {
  --------------------------------------------------------------------
  -- Shorten: target ∈ (last.ppq, last.endppq). Routes durL with a
  -- negative delta; spec carries the change, materialisation re-emits.
  --------------------------------------------------------------------
  {
    name = 'noteOff shorten on aliased child routes durL relative',
    run = function(harness)
      -- Alias resolved: ppqL=240 (row 1), pitch=61, durL=720 → endppqL=960 (row 4).
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}},
                        durL = {{'add', 480}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)

      local kid = aliasKid(h.fm:dump().notes, 1)
      t.eq(kid.ppq,    240)
      t.eq(kid.endppq, 960, 'alias resolved with durL = root.durL(240) + 480')

      -- Cursor at row 2 → target=480. Last in col is the alias (ppq=240).
      -- target < last.endppq → shorten branch. δ_durL = 480 - 960 = -480.
      local colIdx = colAtRow(h.vm.grid, 1, 1)
      h.ec:setPos(2, colIdx, 1)
      h.cmgr:invoke('noteOff')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.aliases[1].xform.durL, {{'add', 0}},
               'coalesce: 480 + (-480) = 0')
      t.eq(root.endppq, 240, 'root tail unchanged')

      local kid2 = aliasKid(h.fm:dump().notes, 1)
      t.truthy(kid2,           'still aliased — no sever')
      t.eq(kid2.endppq, 480,   'resolved endppq follows new durL')
    end,
  },

  --------------------------------------------------------------------
  -- Extend (undo branch): cursor at last.endppq → undo=true. Tail
  -- extends to next note (or take length); routes durL +δ.
  --------------------------------------------------------------------
  {
    name = 'noteOff extend on aliased child routes durL relative (undo branch)',
    run = function(harness)
      -- Alias resolved: ppqL=240, pitch=61, durL=240 → endppqL=480.
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
        -- Tighter take length to keep arithmetic obvious.
      }
      h.vm:setGridSize(80, 40)

      local colIdx = colAtRow(h.vm.grid, 1, 1)
      -- Cursor at row 2 = ppq 480 = alias.endppq → undo=true. No next
      -- note → newEnd = take length = 3840 (default). δ = 3840-480 = 3360.
      h.ec:setPos(2, colIdx, 1)
      h.cmgr:invoke('noteOff')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.aliases[1].xform.durL, {{'add', 3360}},
               'fresh durL op (was absent) appended with extension delta')

      local kid = aliasKid(h.fm:dump().notes, 1)
      t.eq(kid.endppq, 3840, 'tail extended to take length')
    end,
  },

  --------------------------------------------------------------------
  -- Zero-duration branch (target ≤ last.ppq): structural — routes
  -- through deleteAliased so the spec node is removed and its
  -- descendants promote in place. Without this, the materialised
  -- alias would be `deleteEvent`'d but its grandchild's spec would
  -- still emit on the next rebuild — broken state.
  --------------------------------------------------------------------
  {
    name = 'noteOff at last.ppq on aliased child cascade-deletes; descendants promote',
    run = function(harness)
      -- Alias id=1 at row 2 (pitch 61), with grandchild id=1.1 at +240
      -- (row 3, pitch 62) carrying its own durL.
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 480}}, pitch = {{'add', 1}} },
              children = {
                { id = '1', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
                  children = {} },
              }},
          },
        } } },
      }
      h.vm:setGridSize(80, 40)

      local pre = h.fm:dump().notes
      local mid, gk
      for _, n in ipairs(pre) do
        if n.parentUuid == 1 then
          local idx = h.tm:specPathOf(n)
          local key = idx and table.concat(idx, '.') or nil
          if key == '1'   then mid = n end
          if key == '1.1' then gk  = n end
        end
      end
      t.truthy(mid); t.eq(mid.pitch, 61); t.eq(mid.ppq, 480)
      t.truthy(gk);  t.eq(gk.pitch,  62); t.eq(gk.ppq,  720)

      -- Cursor at row 2 (alias's own onset row) = target = mid.ppq → delete branch.
      local colIdx = colAtRow(h.vm.grid, 2, 1)
      h.ec:setPos(2, colIdx, 1)
      h.cmgr:invoke('noteOff')

      local notes = h.fm:dump().notes
      local root  = rootByUuid(notes, 1)
      t.eq(#root.aliases, 0, 'spec node id=1 (with grandchild beneath) removed')

      -- Two notes survive: original root + promoted ex-grandchild.
      t.eq(#notes, 2)
      local promoted
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted,                 'ex-grandchild promoted to free root')
      t.eq(promoted.pitch, 62)
      t.eq(promoted.ppq,   720)
      t.eq(promoted.specPath,   nil)
      t.eq(promoted.parentUuid, nil)
    end,
  },
}
