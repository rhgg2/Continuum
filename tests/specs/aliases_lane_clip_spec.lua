-- Rebuild-side: an alias spec node carrying `fit = true` has its
-- materialised endppq clipped against the next event on the same column
-- (chan + lane), pre-allocator. Lane assignment itself is unchanged —
-- this only adjusts the alias's effective duration, so an over-long fit
-- alias never causes a new lane to be allocated for its successor.

local t = require('support')

local R = 240   -- ppq per row at rowPerBeat = 1, resolution = 240

local function plainNote(uuid, pitch, ppq, endppq, lane)
  return { uuid = uuid, ppq = ppq, endppq = endppq,
           ppqL = ppq, endppqL = endppq,
           chan = 1, pitch = pitch, vel = 100,
           detune = 0, delay = 0, lane = lane or 1 }
end

local function root(extras)
  local n = plainNote(1, 60, 0, R)
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local function aliasChildren(notes, parentUuid)
  local out = {}
  for _, n in ipairs(notes) do
    if n.parentUuid == parentUuid then out[#out+1] = n end
  end
  return out
end

return {
  --------------------------------------------------------------------
  -- 1. fit alias with no same-column successor keeps full duration.
  --------------------------------------------------------------------
  {
    name = 'fit alias with no successor on same column keeps full durL',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = { root{
            aliasCtr = 2,
            aliases  = {
              { id = '1', fit = true,
                xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 8*R}} },
                children = {} },
            },
          } },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(#kids, 1, 'one materialised alias')
      t.eq(kids[1].ppq, 4*R, 'starts at row 4')
      t.eq(kids[1].endppq, 4*R + 9*R, 'full 9-beat span (240 root + 8 added)')
    end,
  },

  --------------------------------------------------------------------
  -- 2. fit alias clips at next same-column event's ppq.
  --------------------------------------------------------------------
  {
    name = 'fit alias clips endppq at next same-column event',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = {
            root{
              aliasCtr = 2,
              aliases  = {
                { id = '1', fit = true,
                  xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 8*R}} },
                  children = {} },
              },
            },
            plainNote(2, 64, 8*R, 9*R),  -- successor at row 8
          },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
      t.eq(kids[1].endppq, 8*R, 'clipped to successor ppq')
    end,
  },

  --------------------------------------------------------------------
  -- 3. non-fit alias on same column does not clip.
  --------------------------------------------------------------------
  {
    name = 'non-fit alias does not clip even with same-column successor',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = {
            root{
              aliasCtr = 2,
              aliases  = {
                { id = '1',  -- no fit
                  xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 8*R}} },
                  children = {} },
              },
            },
            plainNote(2, 64, 8*R, 9*R),
          },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(kids[1].endppq, 4*R + 9*R, 'full duration preserved')
    end,
  },

  --------------------------------------------------------------------
  -- 4. successor on same channel but different lane does not clip.
  --------------------------------------------------------------------
  {
    name = 'fit alias does not clip against same-channel different-lane successor',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = {
            root{
              aliasCtr = 2,
              aliases  = {
                { id = '1', fit = true,
                  xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 8*R}} },
                  children = {} },
              },
            },
            plainNote(2, 64, 8*R, 9*R, 2),  -- lane 2
          },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(kids[1].endppq, 4*R + 9*R, 'different-lane successor does not clip')
    end,
  },

  --------------------------------------------------------------------
  -- 5. reactivity: deleting the successor restores full duration on
  --    the next rebuild.
  --------------------------------------------------------------------
  {
    name = 'deleting same-column successor restores fit alias full duration',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = {
            root{
              aliasCtr = 2,
              aliases  = {
                { id = '1', fit = true,
                  xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 8*R}} },
                  children = {} },
              },
            },
            plainNote(2, 64, 8*R, 9*R),
          },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(kids[1].endppq, 8*R, 'pre-delete: clipped to row 8')

      local victimLoc
      for loc, n in h.fm:notes() do if n.uuid == 2 then victimLoc = loc end end
      h.fm:modify(function() h.fm:deleteNote(victimLoc) end)
      h.tm:rebuild()

      kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
      t.eq(kids[1].endppq, 4*R + 9*R, 'post-delete: full duration restored')
    end,
  },

  --------------------------------------------------------------------
  -- 6. two fit aliases on the same column: earlier clips at later's ppq.
  --    Later has no successor, so its full duration is kept.
  --------------------------------------------------------------------
  {
    name = 'two fit aliases on same column: earlier clips at later ppq',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = { root{
            aliasCtr = 3,
            aliases  = {
              -- Different pitches so step-1 same-pitch truncation doesn't
              -- mask the fit-clip we're trying to test.
              { id = '1', fit = true,
                xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 8*R}} },
                children = {} },
              { id = '2', fit = true,
                xform    = { ppqL = {{'add', 8*R}}, durL = {{'add', 8*R}}, pitch = {{'add', 4}} },
                children = {} },
            },
          } },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      table.sort(kids, function(a, b) return a.ppq < b.ppq end)
      t.eq(#kids, 2)
      t.eq(kids[1].endppq, 8*R, 'first clipped at second ppq')
      t.eq(kids[2].endppq, 8*R + 9*R, 'second keeps full duration')
    end,
  },

  --------------------------------------------------------------------
  -- 7. successor *after* the alias's natural end (gap, no overlap) —
  --    no clip. Pins half-open / no-overlap semantics.
  --------------------------------------------------------------------
  {
    name = 'fit alias whose end precedes successor ppq is not clipped',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = {
            root{
              aliasCtr = 2,
              aliases  = {
                { id = '1', fit = true,
                  xform    = { ppqL = {{'add', 4*R}}, durL = {{'add', 2*R}} },
                  children = {} },
              },
            },
            plainNote(2, 64, 8*R, 9*R),
          },
        },
      }
      local kids = aliasChildren(h.fm:dump().notes, 1)
      t.eq(kids[1].ppq,    4*R, 'starts row 4')
      t.eq(kids[1].endppq, 4*R + 3*R, 'natural end at row 7; successor at row 8 does not pull it back')
    end,
  },
}
