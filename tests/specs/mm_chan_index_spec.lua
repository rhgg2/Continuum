-- Pins the per-channel event index behind mm:notesRaw(chan) / mm:ccsRaw(chan).
-- design/incremental-rebuild.md § The traversal floor.
--
-- The index is maintained by the verbs (add / delete / chan-move) and reconstructed
-- wholesale by the reindex, so a missed maintenance point is SILENT: the channel walk
-- just yields too few events and a gated stage under-derives. Every case here asserts
-- the same net -- one channel's slice of the index is identical, record-for-record and
-- in the same order, to filtering a whole-array walk by that channel.
--
-- Both states matter and they are different code paths: mid-modify the arrays are sparse
-- and only the verbs have touched the index; at unwind the reindex has rebuilt it.

local t = require('support')

local function collect(iter)
  local out = {}
  for _, e in iter do out[#out + 1] = e end
  return out
end

local function onChan(iter, chan)
  local out = {}
  for _, e in iter do
    if e.chan == chan then out[#out + 1] = e end
  end
  return out
end

-- Raw iterators yield mm's own records, so identity comparison is the strongest available check:
-- it catches a stale bucket holding a dead record as readily as a missing one.
local function assertParity(mm, when)
  for chan = 1, 16 do
    local wantNotes, gotNotes = onChan(mm:notesRaw(), chan), collect(mm:notesRaw(chan))
    t.eq(#gotNotes, #wantNotes, when .. ': note count on chan ' .. chan)
    for i = 1, #wantNotes do
      t.eq(gotNotes[i], wantNotes[i], when .. ': note ' .. i .. ' on chan ' .. chan)
    end

    local wantCCs, gotCCs = onChan(mm:ccsRaw(), chan), collect(mm:ccsRaw(chan))
    t.eq(#gotCCs, #wantCCs, when .. ': cc count on chan ' .. chan)
    for i = 1, #wantCCs do
      t.eq(gotCCs[i], wantCCs[i], when .. ': cc ' .. i .. ' on chan ' .. chan)
    end
  end
end

local function fixture(harness)
  return harness.bareMM{
    notes = {
      { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
      { ppq = 240, endppq = 480, chan = 3, pitch = 62, vel = 100 },
      { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 },
      { ppq = 720, endppq = 960, chan = 3, pitch = 67, vel = 100 },
    },
    ccs = {
      { ppq =   0, evType = 'cc', chan = 1, cc = 7,  val = 10 },
      { ppq = 120, evType = 'pb', chan = 3, val = -2048 },
      { ppq = 240, evType = 'cc', chan = 1, cc = 7,  val = 20 },
      { ppq = 360, evType = 'pa', chan = 3, pitch = 62, vel = 40 },
    },
  }
end

return {
  {
    name = 'the reindex reconstructs the index: a freshly loaded take walks per-channel',
    run = function(harness)
      local mm = fixture(harness)
      assertParity(mm, 'after load')
      t.eq(#collect(mm:notesRaw(1)), 2, 'chan 1 holds its two notes')
      t.eq(#collect(mm:notesRaw(2)), 0, 'an empty channel walks empty, not nil')
      t.eq(#collect(mm:ccsRaw(3)),   2, 'chan 3 holds its pb and its pa')
    end,
  },

  {
    name = 'an added note and cc join their channel mid-modify, before any reindex',
    run = function(harness)
      local mm = fixture(harness)
      mm:modify(function()
        mm:add{ evType = 'note', ppq = 960, endppq = 1200, chan = 2, pitch = 70, vel = 100 }
        mm:add{ evType = 'cc',   ppq = 960, chan = 2, cc = 7, val = 30 }
        assertParity(mm, 'mid-modify after add')
        t.eq(#collect(mm:notesRaw(2)), 1, 'the new note is visible on its channel at once')
        t.eq(#collect(mm:ccsRaw(2)),   1, 'and so is the new cc')
      end)
      assertParity(mm, 'after the add unwound')
    end,
  },

  {
    name = 'a delete leaves the channel walk hole-free, mid-modify and after the reindex',
    run = function(harness)
      local mm = fixture(harness)
      local noteTok, ccTok
      for _, n in mm:notesRaw() do if n.ppq == 0   then noteTok = mm:tokenOf(n) end end
      for _, c in mm:ccsRaw()   do if c.ppq == 120 then ccTok   = mm:tokenOf(c) end end

      mm:modify(function()
        mm:delete(noteTok)
        mm:delete(ccTok)
        assertParity(mm, 'mid-modify after delete')
        t.eq(#collect(mm:notesRaw(1)), 1, 'the deleted note is gone from its channel')
        t.eq(#collect(mm:ccsRaw(3)),   1, 'the deleted pb is gone from its channel')
      end)
      assertParity(mm, 'after the delete unwound')
    end,
  },

  {
    name = 'a chan move leaves the old bucket and joins the new one',
    run = function(harness)
      local mm = fixture(harness)
      local noteTok, ccTok
      for _, n in mm:notesRaw() do if n.ppq == 240 then noteTok = mm:tokenOf(n) end end
      for _, c in mm:ccsRaw()   do if c.ppq == 0   then ccTok   = mm:tokenOf(c) end end

      mm:modify(function()
        mm:assign(noteTok, { chan = 5 })   -- chan 3 -> 5
        mm:assign(ccTok,   { chan = 5 })   -- chan 1 -> 5
        assertParity(mm, 'mid-modify after chan move')
        t.eq(#collect(mm:notesRaw(3)), 1, 'the moved note left chan 3')
        t.eq(#collect(mm:notesRaw(5)), 1, 'and arrived on chan 5')
        t.eq(#collect(mm:ccsRaw(1)),   1, 'the moved cc left chan 1')
        t.eq(#collect(mm:ccsRaw(5)),   1, 'and arrived on chan 5')
      end)
      assertParity(mm, 'after the chan move unwound')
    end,
  },

  {
    name = 'a non-structural assign does not disturb the index',
    run = function(harness)
      local mm = fixture(harness)
      local tok
      for _, n in mm:notesRaw() do if n.ppq == 0 then tok = mm:tokenOf(n) end end
      mm:modify(function()
        mm:assign(tok, { detune = 25 })   -- lockless path: no chan, no loc, no membership change
        assertParity(mm, 'mid-modify after a metadata-only assign')
      end)
      assertParity(mm, 'after the metadata-only assign unwound')
    end,
  },

  {
    name = 'a value-only assign keeps the index right with no reindex behind it',
    run = function(harness)
      local mm = fixture(harness)
      local tok
      for _, n in mm:notesRaw() do if n.ppq == 240 then tok = mm:tokenOf(n) end end
      -- Structural, so it takes the locked path, but it moves no ppq: neither flag fires and the
      -- unwind skips the reindex. The verbs' own maintenance is all that stands behind the index.
      mm:modify(function()
        mm:assign(tok, { pitch = 65, vel = 90 })
        assertParity(mm, 'mid-modify after a value-only assign')
      end)
      assertParity(mm, 'after the value-only assign unwound, unlaundered')
    end,
  },

  {
    name = 'the collision backstop kills a note outside mm:delete; the reindex launders it',
    run = function(harness)
      local mm = fixture(harness)
      -- Drive chan 1's two notes onto one (chan, pitch, ppq): the loser is killed by
      -- resolveCollisions, which nils notes[loc] directly rather than routing through mm:delete.
      local tok
      for _, n in mm:notesRaw() do if n.ppq == 480 then tok = mm:tokenOf(n) end end
      mm:modify(function()
        mm:assign(tok, { ppq = 0, endppq = 240, pitch = 60 })
      end)
      assertParity(mm, 'after the backstop resolved the collision')
    end,
  },
}
