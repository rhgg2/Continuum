-- Groups × delay: the gm→tm intent/realisation seam for a pure delay
-- edit. Real tm, real cm (identity swing), real gm wired into the
-- production flush pipeline.
--
-- The incident: a delay edit on one instance pushed every OTHER copy of
-- the note off-grid. tm.realiseNoteUpdate rewrites a {delay=X} update
-- in place to {delay=X, ppq=<raw onset incl. delay>} (no ppqL — delay
-- moves no logical onset). gm reads that same update at preflush;
-- updToGroup/toGroup keyed the group onset off the realised `ppq`, so
-- the delay offset leaked into the group's LOGICAL onset and every
-- sibling reproject re-realised it a second time. Delay is the first
-- edit that breaks raw==logical even under identity swing, so it is
-- where the latent frame confusion surfaces.
--
-- Fix: the group frame is logical. toGroup/updToGroup derive the onset
-- from the logical frame (ppqL) only; a pure delay edit (raw ppq set,
-- no ppqL) moves no group onset — delay travels as the scalar alone.

local t       = require('support')
local harness = require('harness')

-- resolution 240; delay 100 milli-QN -> 24 raw ppq.
local DELAY     = 100
local DELAY_PPQ = 24

local function seededHarness()
  return harness.mk{
    groups = true,
    seed   = { length = 7680, resolution = 240, notes = {
      { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
        chan = 1, lane = 1, pitch = 60, vel = 100, uuid = 1 },
    } },
  }
end

-- One note:1 stream, an 8-row bar wide, anchored at ppq 0.
local RECT = { ppq = 0, dur = 960, chanLo = 1,
               streams = { [0] = { ['note:1'] = true } } }

local function notesByPpq(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.pitch == 60 then out[#out + 1] = n end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

return {
  {
    name = 'a delay edit shifts every copy by the delay, none off-grid',
    run = function()
      local h   = seededHarness()
      local gm  = h.gm
      local src = h.vm:eventsInRect(RECT)[1]

      local gid = gm:markGroup(h.vm:eventsInRect(RECT), RECT)
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()

      -- The production seam: tv's delay edit is exactly this call.
      h.tm:assignEvent(src, { delay = DELAY })
      h.tm:flush()

      local notes = notesByPpq(h)
      t.eq(#notes, 2, 'both copies present')
      t.eq(notes[1].ppq, DELAY_PPQ,
        'origin shifted by the delay (logical 0 + delay)')
      t.eq(notes[2].ppq, 960 + DELAY_PPQ,
        'sibling shifted by the SAME delay, not pushed off-grid ' ..
        '(bug: the delay leaked into the group onset and re-realised)')
    end,
  },

  {
    name = 'a delay edit leaves the group onset logical (fresh instance lands on-grid)',
    run = function()
      local h   = seededHarness()
      local gm  = h.gm
      local src = h.vm:eventsInRect(RECT)[1]

      local gid = gm:markGroup(h.vm:eventsInRect(RECT), RECT)
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()

      h.tm:assignEvent(src, { delay = DELAY })
      h.tm:flush()

      -- A copy dropped AFTER the delay edit must still land at its
      -- anchor's logical onset (+delay). A corrupted group ppq would
      -- bake the first anchor's realised position into the template.
      gm:newInstance(gid, { ppq = 1920, chan = 1 })
      h.tm:flush()

      local third
      for _, n in ipairs(notesByPpq(h)) do
        if n.ppq >= 1920 then third = n end
      end
      t.truthy(third, 'third copy materialised')
      t.eq(third.ppq, 1920 + DELAY_PPQ,
        'group onset stayed logical; new copy lands at anchor + delay')
    end,
  },
}
