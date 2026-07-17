-- Pin-tests for opaque content-keyed addressing on midiManager.
--
-- Token contract:
--   * Built from the event's identity fields (evType, chan, ppq, and
--     pitch|cc as relevant). Opaque to callers; mm:byToken is the inverse.
--   * Stable across reload as long as identity fields don't change.
--   * Exists for every event mm returns — including plain ccs that have
--     no uuid.
--
-- This spec exercises the read side only. Step 3 will add the unified
-- write surface and exercise round-trips through assign / delete.

local t = require('support')

local function token(mm, kind, fields)
  -- Build a probe event matching the seed shape, ask mm for its token.
  local evt = { evType = kind, chan = fields.chan, ppq = fields.ppq }
  if kind == 'note' or kind == 'pa' then evt.pitch = fields.pitch end
  if kind == 'cc' then evt.cc = fields.cc end
  return mm:tokenOf(evt)
end

return {
  {
    name = 'note: tokenOf round-trips through byToken',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, fetched = h.fm:notes()()
      local tok = h.fm:tokenOf(fetched)
      t.truthy(tok, 'tokenOf returned a token')
      local loc, byT = h.fm:byToken(tok)
      t.eq(loc, fetched.loc)
      t.eq(byT.pitch, 60)
      t.eq(byT.chan,  1)
      t.eq(byT.ppq,   0)
    end,
  },

  {
    name = 'cc: tokenOf round-trips for a plain cc',
    run = function(harness)
      local fm = harness.bareMM{ ccs = { { ppq = 120, evType = 'cc', chan = 2, cc = 7, val = 64 } } }
      local tok = token(fm, 'cc', { chan = 2, cc = 7, ppq = 120 })
      local loc, c, kind = fm:byToken(tok)
      t.eq(loc, 1)
      t.eq(kind, 'cc')
      t.eq(c.val, 64)
      t.eq(c.plain, true, 'plain cc — no sidecar, but still addressable by token')
    end,
  },

  {
    name = 'pb / pa / at / pc: every evType yields a working token',
    run = function(harness)
      local fm = harness.bareMM{ ccs = {
        { ppq = 0,   evType = 'pb', chan = 1,             val = -2048 },
        { ppq = 60,  evType = 'pa', chan = 3, pitch = 64, vel =  90   },
        { ppq = 120, evType = 'at', chan = 5,             val =  77   },
        { ppq = 180, evType = 'pc', chan = 7,             val =  12   },
      } }
      local cases = {
        { kind = 'pb', chan = 1, ppq = 0,   field = 'val', want = -2048 },
        { kind = 'pa', chan = 3, ppq = 60,  pitch = 64, field = 'vel', want = 90 },
        { kind = 'at', chan = 5, ppq = 120, field = 'val', want = 77 },
        { kind = 'pc', chan = 7, ppq = 180, field = 'val', want = 12 },
      }
      for _, c in ipairs(cases) do
        local tok = token(fm, c.kind, c)
        local _, evt = fm:byToken(tok)
        t.truthy(evt, c.kind .. ': byToken returned an event')
        t.eq(evt.evType, c.kind)
        t.eq(evt[c.field], c.want, c.kind .. '.' .. c.field)
      end
    end,
  },

  {
    name = 'tokens are stable across reload',
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

      h.fm:reload()

      local _, n2 = h.fm:byToken(nTok)
      local _, c2 = h.fm:byToken(cTok)
      t.truthy(n2, 'note token survives reload')
      t.truthy(c2, 'cc token survives reload')
      t.eq(n2.pitch, 60)
      t.eq(c2.val,   64)
    end,
  },

  {
    name = 'mutating an identity field retires the old token',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, note = h.fm:notes()()
      local oldTok = h.fm:tokenOf(note)

      h.fm:modify(function() h.fm:assign(oldTok, { ppq = 480 }) end)

      t.eq(h.fm:byToken(oldTok), nil, 'old (ppq=0) token no longer resolves')
      local _, moved = h.fm:notes()()
      local newTok = h.fm:tokenOf(moved)
      t.truthy(newTok ~= oldTok, 'new token differs from the retired one')
      local _, byNew = h.fm:byToken(newTok)
      t.eq(byNew.ppq, 480)
    end,
  },

  {
    name = 'distinct events with overlapping fields get distinct tokens',
    run = function(harness)
      -- A note and a pa at the same (chan, pitch, ppq); a cc#7 vs cc#10
      -- at the same (chan, ppq); a pb at the same (chan, ppq) as an at.
      local fm = harness.bareMM{
        notes = { { ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100 } },
        ccs   = {
          { ppq = 0,  evType = 'pa', chan = 1, pitch = 60, vel = 50 },
          { ppq = 60, evType = 'cc', chan = 2, cc = 7,  val = 10 },
          { ppq = 60, evType = 'cc', chan = 2, cc = 10, val = 20 },
          { ppq = 90, evType = 'pb', chan = 3, val = 0 },
          { ppq = 90, evType = 'at', chan = 3, val = 30 },
        },
      }
      local toks = {}
      for _, n in fm:notes() do toks[#toks+1] = fm:tokenOf(n) end
      for _, c in fm:ccs()   do toks[#toks+1] = fm:tokenOf(c) end
      local seen = {}
      for _, tok in ipairs(toks) do
        t.falsy(seen[tok], 'duplicate token: ' .. tostring(tok))
        seen[tok] = true
      end
      t.eq(#toks, 6, 'all six events present')
    end,
  },

  {
    name = 'tokenOf returns nil for a non-event',
    run = function(harness)
      local h = harness.mk{}
      t.eq(h.fm:tokenOf(nil), nil)
      t.eq(h.fm:tokenOf({}), nil, 'no evType — no token')
    end,
  },

  {
    name = 'byToken returns nil for an unknown token',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      t.eq(h.fm:byToken('note|1|99|0'), nil)
      t.eq(h.fm:byToken(''), nil)
    end,
  },
}
