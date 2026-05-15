-- Phase 2 reconciliation: synthetic-root materialisation in tm.
-- See design/blocks.md (Reconciliation pass).

local t = require('support')

local function bySynth(notes, synthUuid)
  local out = {}
  for _, n in ipairs(notes) do
    if n.parentUuid == synthUuid then out[#out+1] = n end
  end
  return out
end

local function ccsBySynth(ccs, synthUuid)
  local out = {}
  for _, c in ipairs(ccs) do
    if c.parentUuid == synthUuid then out[#out+1] = c end
  end
  return out
end

local function mkRegionsBlob(regions)
  return { regions = regions, idCtr = #regions }
end

return {
  --------------------------------------------------------------------
  -- Identity: one template event, no xform
  --------------------------------------------------------------------
  {
    name = 'identity emit: one template event materialises at region.ppqLo + te.ppqL',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 480, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 240 },
              },
            },
          },
        } } },
      }
      local kids = bySynth(h.fm:dump().notes, 'synth:1:1')
      t.eq(#kids, 1, 'one materialisation per template event')
      t.eq(kids[1].ppq,    480,  'ppq = ppqLo + ppqL')
      t.eq(kids[1].endppq, 720,  'endppq = ppq + durL')
      t.eq(kids[1].pitch,  60)
      t.eq(kids[1].vel,    96)
      t.eq(kids[1].chan,   1)
      t.eq(kids[1].lane,   1)
    end,
  },

  --------------------------------------------------------------------
  -- Star geometric xform shifts every template event
  --------------------------------------------------------------------
  {
    name = "star xform: ppqL +480 shifts the materialisation",
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 240 },
              },
            },
            xform = { ['*'] = { ppqL = {{'add', 480}} } },
          },
        } } },
      }
      local kids = bySynth(h.fm:dump().notes, 'synth:1:1')
      t.eq(#kids, 1)
      t.eq(kids[1].ppq,    480, 'ppqL +480 lands at 480')
      t.eq(kids[1].endppq, 720)
    end,
  },

  --------------------------------------------------------------------
  -- Per-colKey content xform composes only on matching template events
  --------------------------------------------------------------------
  {
    name = 'col xform: pitch +12 on this col only',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 2,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 240 },
                ['2'] = { col = 'note:1:2:pitch', ppqL = 240,
                          pitch = 64, vel = 96, durL = 240 },
              },
            },
            xform = {
              ['note:1:1:pitch'] = { pitch = {{'add', 12}} },
            },
          },
        } } },
      }
      local k1 = bySynth(h.fm:dump().notes, 'synth:1:1')[1]
      local k2 = bySynth(h.fm:dump().notes, 'synth:1:2')[1]
      t.eq(k1.pitch, 72, 'col-keyed xform applies to this template event')
      t.eq(k2.pitch, 64, 'other template events untouched')
    end,
  },

  --------------------------------------------------------------------
  -- Composition order: star then col on the same field
  --------------------------------------------------------------------
  {
    name = 'compose: star vel +10 then col vel *2 (64 → 74 → 148)',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 64, durL = 240 },
              },
            },
            xform = {
              ['*']                = { vel = {{'add', 10}} },
              ['note:1:1:pitch']   = { vel = {{'mul',  2}} },
            },
          },
        } } },
      }
      local k = bySynth(h.fm:dump().notes, 'synth:1:1')[1]
      t.eq(k.vel, 148, 'star applies first, then col')
    end,
  },

  --------------------------------------------------------------------
  -- Multiple template events → multiple materialisations
  --------------------------------------------------------------------
  {
    name = 'multiple template events emit independently',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 3,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 120 },
                ['2'] = { col = 'note:1:1:pitch', ppqL = 240,
                          pitch = 62, vel = 96, durL = 120 },
                ['3'] = { col = 'note:1:1:pitch', ppqL = 480,
                          pitch = 64, vel = 96, durL = 120 },
              },
            },
          },
        } } },
      }
      local notes = h.fm:dump().notes
      t.eq(#bySynth(notes, 'synth:1:1'), 1)
      t.eq(#bySynth(notes, 'synth:1:2'), 1)
      t.eq(#bySynth(notes, 'synth:1:3'), 1)
      t.eq(bySynth(notes, 'synth:1:1')[1].pitch, 60)
      t.eq(bySynth(notes, 'synth:1:2')[1].pitch, 62)
      t.eq(bySynth(notes, 'synth:1:3')[1].pitch, 64)
    end,
  },

  --------------------------------------------------------------------
  -- Mixed event types in one block
  --------------------------------------------------------------------
  {
    name = 'mixed-type block: note and cc template events both emit',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true, ['cc:1:74'] = true },
            template = {
              eventCtr = 2,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 240 },
                ['2'] = { col = 'cc:1:74', ppqL = 120, val = 100 },
              },
            },
          },
        } } },
      }
      local dump = h.fm:dump()
      local note = bySynth(dump.notes, 'synth:1:1')[1]
      local cc   = ccsBySynth(dump.ccs, 'synth:1:2')[1]
      t.truthy(note, 'note materialisation present')
      t.eq(note.pitch, 60)
      t.truthy(cc, 'cc materialisation present')
      t.eq(cc.evType, 'cc')
      t.eq(cc.cc,     74)
      t.eq(cc.chan,   1)
      t.eq(cc.val,    100)
      t.eq(cc.ppq,    120)
    end,
  },

  --------------------------------------------------------------------
  -- Cross-type fail-closed via aliases.applyXform
  --------------------------------------------------------------------
  {
    name = 'cross-type fail-closed: xform[*].pitch on a cc block is skipped',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['cc:1:74'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['1'] = { col = 'cc:1:74', ppqL = 0, val = 100 },
              },
            },
            xform = {
              ['*'] = { pitch = {{'add', 12}} },     -- not in CC_FIELDS, skipped
              ['cc:1:74'] = { val = {{'add', 5}} },  -- in CC_FIELDS, applies
            },
          },
        } } },
      }
      local cc = ccsBySynth(h.fm:dump().ccs, 'synth:1:1')[1]
      t.eq(cc.val, 105, 'val composes; pitch silently skipped')
    end,
  },

  --------------------------------------------------------------------
  -- Snap op
  --------------------------------------------------------------------
  {
    name = 'snap: ppqL snapped to 240 lands the emit on a grid line',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 130,
                          pitch = 60, vel = 96, durL = 120 },
              },
            },
            xform = { ['*'] = { ppqL = {{'snap', 240}} } },
          },
        } } },
      }
      local k = bySynth(h.fm:dump().notes, 'synth:1:1')[1]
      t.eq(k.ppq, 240, '130 snaps to 240')
    end,
  },

  --------------------------------------------------------------------
  -- te.spec.xform applies as per-event override on top of region.xform
  --------------------------------------------------------------------
  {
    name = 'per-event override: te.spec.xform composes after region.xform',
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 240,
                          spec = { xform = { vel = {{'add', 5}} },
                                   children = {} } },
              },
            },
            xform = { ['*'] = { vel = {{'add', 10}} } },
          },
        } } },
      }
      local k = bySynth(h.fm:dump().notes, 'synth:1:1')[1]
      t.eq(k.vel, 111, 'region.xform (+10) then te.spec.xform (+5): 96 → 106 → 111')
    end,
  },

  --------------------------------------------------------------------
  -- Sweep cleans synth-parented events when block empties
  --------------------------------------------------------------------
  {
    name = 'template emptied → previously-emitted block events sweep next rebuild',
    run = function(harness)
      local blob = mkRegionsBlob{
        { id = 1, colour = 1, ppqLo = 0, ppqHi = 960,
          parts = { ['note:1:1:pitch'] = true },
          template = {
            eventCtr = 1,
            events = {
              ['1'] = { col = 'note:1:1:pitch', ppqL = 0,
                        pitch = 60, vel = 96, durL = 240 },
            },
          },
        },
      }
      local h = harness.mk{ config = { take = { regions = blob } } }
      t.eq(#bySynth(h.fm:dump().notes, 'synth:1:1'), 1)

      -- Empty the template, rewrite the blob, rebuild.
      blob.regions[1].template.events = {}
      h.cm:set('take', 'regions', blob)
      h.tm:rebuild(false)
      t.eq(#bySynth(h.fm:dump().notes, 'synth:1:1'), 0,
           'no synth-parented events remain after template empties')
    end,
  },

  --------------------------------------------------------------------
  -- Empty cm.regions does not perturb existing tm behaviour
  --------------------------------------------------------------------
  {
    name = 'no blocks: walker is inert (no synth events emitted)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        } },
      }
      local notes = h.fm:dump().notes
      t.eq(#notes, 1)
      t.falsy(notes[1].parentUuid)
    end,
  },

  --------------------------------------------------------------------
  -- Synth uuid is a string with the 'synth:' prefix; mm:byUuid won't hit it
  --------------------------------------------------------------------
  {
    name = "synth uuid is a 'synth:<id>:<vuid>' string and does not collide with mm uuids",
    run = function(harness)
      local h = harness.mk{
        config = { take = { regions = mkRegionsBlob{
          { id = 7, colour = 1, ppqLo = 0, ppqHi = 240,
            parts = { ['note:1:1:pitch'] = true },
            template = {
              eventCtr = 1,
              events = {
                ['3'] = { col = 'note:1:1:pitch', ppqL = 0,
                          pitch = 60, vel = 96, durL = 240 },
              },
            },
          },
        } } },
      }
      local k = bySynth(h.fm:dump().notes, 'synth:7:3')[1]
      t.truthy(k, 'synth uuid composed from region.id and vuid')
      t.eq(select(2, h.fm:byUuid('synth:7:3')), nil, 'mm:byUuid returns nil for synth uuids')
    end,
  },
}
