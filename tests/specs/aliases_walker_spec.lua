-- Walker pre-pass exercised through tm:rebuild against seeded mm state.

local t = require('support')

local function byParent(list, uuid)
  local out = {}
  for _, e in ipairs(list) do
    if e.parentUuid == uuid then out[#out+1] = e end
  end
  return out
end

local function specPaths(h, list)
  local out = {}
  for _, e in ipairs(list) do
    local idx = h.tm:specPathOf(e)
    out[#out+1] = idx and table.concat(idx, '.') or '<root>'
  end
  table.sort(out)
  return out
end

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
              chan = 1, pitch = 60, vel = 100, uuid = 1 }
  for k, v in pairs(extras) do n[k] = v end
  return n
end

return {
  --------------------------------------------------------------------
  -- Single-level emit
  --------------------------------------------------------------------
  {
    name = 'single-level emit: ppq+480 shifts the whole note',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
      t.eq(kids[1].ppq,    480)
      t.eq(kids[1].endppq, 720)         -- dur preserved at 240
      t.eq(kids[1].pitch,  60)
      t.eq(kids[1].vel,    100)
      t.deepEq(h.tm:specPathOf(kids[1]), {1})
    end,
  },

  --------------------------------------------------------------------
  -- Three-level transitive composition
  --------------------------------------------------------------------
  {
    name = 'three-level transitive: ppq+200 → *2 → +ppq+1, vel+10',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 200}} }, children = {
              { id = '1', xform = { ppqL = {{'mul', 2}} }, children = {
                { id = '1', xform = { ppqL = {{'add', 1}}, vel = {{'add', 10}} },
                  children = {} },
              }},
            }},
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 3)
      t.deepEq(specPaths(h, kids), { '1', '1.1', '1.1.1' })
      local byPath = {}
      for _, k in ipairs(kids) do
        byPath[table.concat(h.tm:specPathOf(k), '.')] = k
      end
      t.eq(byPath['1'    ].ppq, 200);  t.eq(byPath['1'    ].vel, 100)
      t.eq(byPath['1.1'  ].ppq, 400);  t.eq(byPath['1.1'  ].vel, 100)
      t.eq(byPath['1.1.1'].ppq, 401);  t.eq(byPath['1.1.1'].vel, 110)
      t.eq(byPath['1.1.1'].endppq, 641)
    end,
  },

  --------------------------------------------------------------------
  -- Length clamp: a materialised tail past the take's end is pulled
  -- back to length, with endppqL recomputed in the same channel's
  -- swing frame so the canonical logical end stays coherent.
  --------------------------------------------------------------------
  {
    name = 'walker clamps endppq AND endppqL to take length',
    run = function(harness)
      local h = harness.mk{
        seed = {
          length = 480,
          notes  = { rootNote{
            ppq = 0, endppq = 240,
            aliasCtr = 2,
            children = {
              -- shift +480 → start 480, would-be end 720; tail clamps to 480.
              { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
            },
          } },
        },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
      t.eq(kids[1].endppq,  480, 'endppq clamped to take length')
      t.eq(kids[1].endppqL, 480, 'endppqL coherent with clamped endppq under identity swing')
    end,
  },

  --------------------------------------------------------------------
  -- Idempotence under repeated rebuild
  --------------------------------------------------------------------
  {
    name = 'idempotent: second rebuild leaves the materialised set unchanged',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      local before = h.fm:dump().notes
      h.tm:rebuild(false)
      local after  = h.fm:dump().notes
      t.eq(#after, #before)
      t.bagEq(
        { after [1].ppq, after [2].ppq },
        { before[1].ppq, before[2].ppq })
    end,
  },

  --------------------------------------------------------------------
  -- Slot collision suppresses the leaf
  --------------------------------------------------------------------
  {
    name = 'slot collision: a non-alias note at the target slot suppresses emit',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          rootNote{
            aliasCtr = 2,
            children = {
              { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
            },
          },
          { ppq = 480, endppq = 720, chan = 1, pitch = 60, vel = 70 },
        } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 0, 'leaf suppressed by blocker')
    end,
  },

  --------------------------------------------------------------------
  -- Resurface after blocker removed
  --------------------------------------------------------------------
  {
    name = 'resurface: removing the blocker lets the materialised note appear',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          rootNote{
            aliasCtr = 2,
            children = {
              { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
            },
          },
          { ppq = 480, endppq = 720, chan = 1, pitch = 60, vel = 70 },
        } },
      }
      t.eq(#byParent(h.fm:dump().notes, 1), 0)

      local blockerLoc
      for loc, n in h.fm:notes() do
        if not n.children and n.ppq == 480 then blockerLoc = loc end
      end
      h.fm:modify(function() h.fm:deleteNote(blockerLoc) end)

      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
      t.eq(kids[1].ppq, 480)
    end,
  },

  --------------------------------------------------------------------
  -- Mid-tree suppression: descendant still resolves from would-be parent
  --------------------------------------------------------------------
  {
    name = 'mid-tree suppression: child suppressed, grandchild emits',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          rootNote{
            aliasCtr = 2,
            children = {
              { id = '1', xform = { ppqL = {{'add', 480}} }, children = {
                { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
              }},
            },
          },
          { ppq = 480, endppq = 720, chan = 1, pitch = 60, vel = 70 },
        } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
      t.deepEq(h.tm:specPathOf(kids[1]), {1,1})
      t.eq(kids[1].ppq,    960)
      t.eq(kids[1].endppq, 1200)
    end,
  },

  --------------------------------------------------------------------
  -- Metadata fields surface on materialised events
  --------------------------------------------------------------------
  {
    name = 'metadata: parentUuid rides on the materialised note; specPath is derived via tm',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(kids[1].parentUuid, 1)
      t.eq(kids[1].specPath, nil, 'specPath no longer persisted on the materialised event')
      t.deepEq(h.tm:specPathOf(kids[1]), {1})
    end,
  },

  --------------------------------------------------------------------
  -- Re-entry: walker's mm:modify fires reload; outer rebuild bails on
  -- the recursive entry and completes once. The fake mm asserts on
  -- re-entrant modify, so a recursive walk would surface as failure.
  --------------------------------------------------------------------
  {
    name = 're-entry guard: rebuild completes once under cascading reload',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        } } },
      }
      local kids = byParent(h.fm:dump().notes, 1)
      t.eq(#kids, 1)
    end,
  },

  --------------------------------------------------------------------
  -- Determinism: same take id, same materialised values across rebuilds
  --------------------------------------------------------------------
  {
    name = 'determinism: rand draws are identical across two harnesses',
    run = function(harness)
      local function build()
        return harness.mk{
          seed = { notes = { rootNote{
            aliasCtr = 2,
            children = {
              { id = '1', xform = { ppqL = {{'add', {'rand', 0, 1000}}} },
                children = {} },
            },
          } } },
        }
      end
      local a = byParent(build().fm:dump().notes, 1)[1]
      local b = byParent(build().fm:dump().notes, 1)[1]
      t.eq(a.ppq, b.ppq)
    end,
  },

  --------------------------------------------------------------------
  -- Idle case: nothing to do
  --------------------------------------------------------------------
  {
    name = 'idle: no roots, no parentUuid events → walker is inert',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100 },
          { ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 100 },
        } },
      }
      local notes = h.fm:dump().notes
      t.eq(#notes, 2)
      t.falsy(notes[1].parentUuid)
      t.falsy(notes[2].parentUuid)
    end,
  },
}
