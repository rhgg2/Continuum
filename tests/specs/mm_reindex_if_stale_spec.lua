-- Pins the reindex gate: an add/ppq move unsorts, a delete holes, an assign touching neither
-- skips the reindex outright -- and a missed flag fails silently. design/archive/incremental-rebuild.md § 6.

local t = require('support')

local function tokPpqs(mm)
  local out = {}
  for tok, e in mm:events() do out[#out + 1] = tok .. '@' .. e.ppq end
  return out
end

local function noteField(mm, field)
  local out = {}
  for _, n in mm:notesRaw() do out[#out + 1] = n[field] end
  return out
end

local function pair(harness)
  return harness.bareMM{ notes = {
    { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
    { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
  } }
end

local function tokenAtPpq(mm, ppq)
  for _, n in mm:notesRaw() do if n.ppq == ppq then return mm:tokenOf(n) end end
end

return {
  {
    name = 'reindexIfStale() is a no-op on already-compact state',
    run = function(harness)
      local mm = harness.bareMM{
        notes = {
          { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
          { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
        },
        ccs = {
          { ppq = 120, evType = 'cc', chan = 1, cc = 7, val = 10 },
        },
      }
      local before = tokPpqs(mm)
      mm:reindexIfStale()
      t.deepEq(tokPpqs(mm), before, 'events unchanged - no reindex fired')
    end,
  },

  {
    name = 'reindexIfStale() stays inert after a compacting modify',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
        { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 },
      } }
      local midTok
      for _, n in mm:notes() do if n.ppq == 240 then midTok = mm:tokenOf(n) end end
      mm:modify(function() mm:delete(midTok) end)   -- rebuild at unwind clears staleness

      local after = tokPpqs(mm)
      mm:reindexIfStale()
      t.deepEq(tokPpqs(mm), after, 'compacted survivors untouched - flag already clear')
    end,
  },

  {
    name = 'a value-only assign is index-clean: the verb keeps its own index, nothing launders it',
    run = function(harness)
      local mm  = pair(harness)
      local tok = tokenAtPpq(mm, 0)

      -- Structural (so it takes the locked path) but it moves no ppq: neither flag fires, so
      -- no rebuild runs at the unwind. The verb's own re-key is all that maintains the indices.
      local same
      mm:modify(function() same = mm:assign(tok, { pitch = 65, vel = 90 }) end)
      t.eq(same, tok, 'identity is stable across a pitch change')

      local resolved
      mm:modify(function() resolved = mm:assign(tok, { vel = 80 }) end)
      t.truthy(resolved, 'the handle still resolves with no reindex behind it')

      t.deepEq(noteField(mm, 'ppq'),   { 0, 240 }, 'order stands: nothing moved')
      t.deepEq(noteField(mm, 'loc'),   { 1, 2 },   'and loc still matches the array')
      t.deepEq(noteField(mm, 'pitch'), { 65, 62 }, 'the assign landed')
      t.deepEq(noteField(mm, 'vel'),   { 80, 100 }, 'and so did the second')
    end,
  },

  {
    name = 'a ppq move re-sorts the arrays; it leaves no hole to compact',
    run = function(harness)
      local mm  = pair(harness)
      local tok = tokenAtPpq(mm, 0)
      mm:modify(function() mm:assign(tok, { ppq = 480, endppq = 720 }) end)

      t.deepEq(noteField(mm, 'ppq'),   { 240, 480 }, 'the moved note re-sorted behind its neighbour')
      t.deepEq(noteField(mm, 'pitch'), { 62, 60 },   'and it is the moved note that is now last')
      t.deepEq(noteField(mm, 'loc'),   { 1, 2 },     'loc was recomputed to match')
    end,
  },

  {
    name = 'an add sorts into place; a delete compacts around the hole',
    run = function(harness)
      local mm = pair(harness)
      mm:modify(function()
        mm:add{ evType = 'note', ppq = 120, endppq = 240, chan = 1, pitch = 61, vel = 100 }
      end)
      t.deepEq(noteField(mm, 'ppq'), { 0, 120, 240 }, 'the appended note sorted into place')
      t.deepEq(noteField(mm, 'loc'), { 1, 2, 3 },     'loc follows the sorted array')

      mm:modify(function() mm:delete(tokenAtPpq(mm, 120)) end)
      t.deepEq(noteField(mm, 'ppq'), { 0, 240 }, 'the delete compacted out')
      t.deepEq(noteField(mm, 'loc'), { 1, 2 },   'and loc closed the hole')
    end,
  },
}
