-- Pin-tests for the unified token-keyed write/iter surface on midiManager:
--   mm:add(t) → token
--   mm:assign(token, t) → token'
--   mm:delete(token)
--   mm:events() → token, evt iterator
--
-- The loc-form methods (addNote/addCC/assignNote/assignCC/deleteNote/deleteCC)
-- still exist alongside in this step; tm migrates in step 4. These tests
-- exercise the unified surface in isolation.

local t = require('support')

return {
  {
    name = 'add(note): returns a token that resolves to the new note',
    run = function(harness)
      local h = harness.mk{}
      local tok
      h.fm:modify(function()
        tok = h.fm:add{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 }
      end)
      t.truthy(tok, 'add returned a token')
      local _, n = h.fm:byToken(tok)
      t.eq(n.pitch, 60)
      t.eq(n.chan,  1)
      t.eq(n.ppq,   0)
    end,
  },

  {
    name = 'add(cc/pb/pa/at/pc): every evType lands and is byToken-addressable',
    run = function(harness)
      local fm = harness.bareMM()
      local toks = {}
      fm:modify(function()
        toks.cc = fm:add{ evType = 'cc', ppq = 60,  chan = 2, cc = 7,            val = 64   }
        toks.pb = fm:add{ evType = 'pb', ppq = 0,   chan = 1,                    val = -2048 }
        toks.pa = fm:add{ evType = 'pa', ppq = 30,  chan = 3, pitch = 64, vel = 90 }
        toks.at = fm:add{ evType = 'at', ppq = 120, chan = 5,                    val = 77 }
        toks.pc = fm:add{ evType = 'pc', ppq = 180, chan = 7,                    val = 12 }
      end)
      for kind, tok in pairs(toks) do
        local _, evt = fm:byToken(tok)
        t.truthy(evt, kind .. ': byToken found the event')
        t.eq(evt.evType, kind)
      end
    end,
  },

  {
    name = 'assign: metadata-only change preserves the token',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, note = h.fm:notes()()
      local oldTok = h.fm:tokenOf(note)
      local newTok
      h.fm:modify(function() newTok = h.fm:assign(oldTok, { delay = 12 }) end)
      t.eq(newTok, oldTok, 'metadata-only — token unchanged')
      local _, n2 = h.fm:byToken(oldTok)
      t.eq(n2.delay, 12)
    end,
  },

  {
    name = 'assign: identity-field change retires the old token, returns the new one',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, note = h.fm:notes()()
      local oldTok = h.fm:tokenOf(note)
      local newTok
      h.fm:modify(function() newTok = h.fm:assign(oldTok, { ppq = 480 }) end)
      t.truthy(newTok ~= oldTok, 'token changed')
      t.eq(h.fm:byToken(oldTok), nil, 'old token retired')
      local _, n2 = h.fm:byToken(newTok)
      t.eq(n2.ppq, 480)
    end,
  },

  {
    name = 'assign: cc identity change (chan or cc#) re-keys',
    run = function(harness)
      local fm = harness.bareMM{ ccs = { { ppq = 120, evType = 'cc', chan = 2, cc = 7, val = 64 } } }
      local _, cc = fm:ccs()()
      local oldTok = fm:tokenOf(cc)
      local newTok
      fm:modify(function() newTok = fm:assign(oldTok, { cc = 10 }) end)
      t.truthy(newTok ~= oldTok)
      t.eq(fm:byToken(oldTok), nil)
      local _, c2 = fm:byToken(newTok)
      t.eq(c2.cc, 10)
    end,
  },

  {
    name = 'delete(token): event vanishes from byToken and from the iterators',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
          ccs   = { { ppq = 120, evType = 'cc', chan = 2, cc = 7, val = 64 } },
        },
      }
      local _, note = h.fm:notes()()
      local _, cc   = h.fm:ccs()()
      local nTok, cTok = h.fm:tokenOf(note), h.fm:tokenOf(cc)

      h.fm:modify(function() h.fm:delete(nTok) end)
      t.eq(h.fm:byToken(nTok), nil, 'note gone')
      t.truthy(h.fm:byToken(cTok), 'cc still present')

      h.fm:modify(function() h.fm:delete(cTok) end)
      t.eq(h.fm:byToken(cTok), nil, 'cc gone')

      local count = 0
      for _ in h.fm:events() do count = count + 1 end
      t.eq(count, 0, 'events() yields nothing after both deletes')
    end,
  },

  {
    name = 'delete(unknown token): silent no-op',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      h.fm:modify(function() h.fm:delete('note|9|99|999') end)
      local count = 0
      for _ in h.fm:events() do count = count + 1 end
      t.eq(count, 1, 'still one event after no-op delete')
    end,
  },

  {
    name = 'events(): yields all live events as (token, evt), notes then ccs',
    run = function(harness)
      local fm = harness.bareMM{
        notes = {
          { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100 },
          { ppq = 240, endppq = 360, chan = 1, pitch = 64, vel = 100 },
        },
        ccs = {
          { ppq = 60,  evType = 'cc', chan = 2, cc = 7, val = 64 },
          { ppq = 180, evType = 'pb', chan = 1, val = 0 },
        },
      }
      local seen, kinds = {}, {}
      for tok, evt in fm:events() do
        seen[#seen+1] = tok
        kinds[#kinds+1] = evt.evType
        local _, fetched = fm:byToken(tok)
        t.truthy(fetched, 'token from events() resolves via byToken')
      end
      t.eq(#seen, 4, 'four events yielded')
      t.eq(kinds[1], 'note', 'notes come first')
      t.eq(kinds[2], 'note')
      t.truthy(kinds[3] == 'cc' or kinds[3] == 'pb', 'ccs follow')
    end,
  },

  {
    name = 'add(nil) / add{} / assign(nil, t): nil-paths return nil, no crash',
    run = function(harness)
      local h = harness.mk{}
      h.fm:modify(function()
        t.eq(h.fm:add(nil), nil)
        t.eq(h.fm:add{}, nil, 'no evType — no add')
        t.eq(h.fm:assign('bogus', { vel = 80 }), nil)
        h.fm:delete('also-bogus')
      end)
    end,
  },
}
