-- Phase 5.3: quantize severs aliased children before writing through.
-- See design/aliases.md. The materialised event's mm-uuid is preserved by
-- sever, so the quantize plan keyed on the same `e` reference still hits
-- the right loc; the metadata-clear assign and the ppq/endppq writes
-- merge by-loc inside one flush. Aliasing roots are NOT severed —
-- a root that quantizes carries its descendants along via the next
-- rebuild's spec walk against the new root ppq.
--
-- Note on test setup. Two same-pitch aliased children in one column
-- run through conformOverlaps' tail-clip path; uuid_2.endppqL is not
-- clamped by the walker's clearSameKeyRange (only endppq is), so uuid_3
-- gets pushed forward by the residual logical overlap. Avoid the
-- artefact by giving children distinct pitches via a `pitch` xform —
-- the lane allocator splits them into separate columns and the plans
-- don't interact.

local t = require('support')

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

local function byParent(list, uuid)
  local out = {}
  for _, e in ipairs(list) do
    if e.parentUuid == uuid then out[#out + 1] = e end
  end
  return out
end

local function freeRoots(list)
  local out = {}
  for _, e in ipairs(list) do
    if not e.parentUuid then out[#out + 1] = e end
  end
  return out
end

-- ppqPerRow=60 (resolution=240, rowPerBeat=4): row 4=240, row 5=300.
-- 250 → row 4.16 → snap row 4 → 240.
-- 290 → row 4.83 → snap row 5 → 300.
--
-- Multi-child setups use shortNote (durL=60 = one row) to keep children's
-- tails from overlapping the next child's onset — conformOverlaps would
-- otherwise pull a planned successor forward by the residual logical
-- overlap (the lane allocator sticks emits in lane 1 once they were
-- emitted there, so distinct pitches alone don't separate them).
local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local function shortNote(extras)
  local n = { ppq = 0, endppq = 60, ppqL = 0, endppqL = 60,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local CFG = { config = { take = { rowPerBeat = 4 } } }

return {
  --------------------------------------------------------------------
  -- Aliased child off-grid: quantize severs it; promoted root sits
  -- at the snapped ppq; spec node gone from the original root.
  --------------------------------------------------------------------
  {
    name = 'quantize on an off-grid aliased child severs and snaps it',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      local kid = byParent(h.fm:dump().notes, 1)[1]
      t.truthy(kid); t.eq(kid.ppq, 250); t.eq(kid.pitch, 61)

      h.vm:quantizeAll()

      local notes = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.deepEq(oldRoot.aliases, {}, 'spec node plucked from old root')

      local promoted
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted, 'promoted root present')
      t.eq(promoted.ppq,   240, 'snapped to row 4')
      t.eq(promoted.pitch,  61, 'pitch preserved')
      t.eq(promoted.parentUuid, nil)
      t.eq(promoted.specPath,   nil)
    end,
  },

  --------------------------------------------------------------------
  -- Two aliased children of the same root in one quantize: batched
  -- sever — the bug a per-event tm:sever loop would hit (the second
  -- assign of root.aliases would clobber the first's pluck).
  --------------------------------------------------------------------
  {
    name = 'quantize on two aliased children of one root: both severed in one batch',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {} },
            { id = '2',
              xform = { ppqL = {{'add', 290}}, pitch = {{'add', 2}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      t.eq(#byParent(h.fm:dump().notes, 1), 2, 'both children materialised')

      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.deepEq(oldRoot.aliases, {},
        'both spec nodes plucked — not just one (batched sever)')

      local promoted = {}
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted[n.pitch] = n end
      end
      t.truthy(promoted[61], 'first child promoted (pitch 61)')
      t.truthy(promoted[62], 'second child promoted (pitch 62)')
      t.eq(promoted[61].ppq, 240, 'first snapped to row 4')
      t.eq(promoted[62].ppq, 300, 'second snapped to row 5')
    end,
  },

  --------------------------------------------------------------------
  -- On-grid aliased child stays attached: severing only fires for
  -- events that actually have a quantize plan.
  --------------------------------------------------------------------
  {
    name = 'on-grid aliased child stays attached when sibling quantizes',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },  -- on-grid (240=row 4)
            { id = '2',
              xform = { ppqL = {{'add', 290}}, pitch = {{'add', 2}} },
              children = {} },  -- off-grid (290 → row 4.83 → 300)
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 1, 'on-grid sibling stays in spec tree')
      t.eq(oldRoot.aliases[1].id, '1', 'the on-grid one (id=1) survives')

      local kids = byParent(notes, 1)
      t.eq(#kids, 1)
      t.eq(kids[1].pitch, 61)
      t.eq(kids[1].specPath, '1')

      -- The off-grid one is now a free promoted root.
      local promoted
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted)
      t.eq(promoted.ppq,   300)
      t.eq(promoted.pitch, 62)
    end,
  },

  --------------------------------------------------------------------
  -- Aliasing root with nothing to quantize: root keeps its `aliases`
  -- list; not severed. Proves the pre-pass filters by parentUuid.
  --------------------------------------------------------------------
  {
    name = 'aliasing root with on-grid child: no plans, root preserved intact',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.truthy(oldRoot, 'root not severed away')
      t.eq(#oldRoot.aliases, 1, 'spec tree preserved when nothing planned')
      t.eq(oldRoot.aliases[1].id, '1')

      local kids = byParent(notes, 1)
      t.eq(#kids, 1, 'child still materialised under the root')
      t.eq(kids[1].specPath, '1', 'still aliased — not promoted')
    end,
  },

  --------------------------------------------------------------------
  -- Aliased child with a grandchild spec: after sever the grandchild
  -- re-emits relative to the promoted (now quantized) root position.
  -- Grandchild is on-grid relative to the post-quantize mid, so it is
  -- not itself planned — it stays attached and follows.
  --------------------------------------------------------------------
  {
    name = 'severed child carries its subtree; grandchild composes against new root',
    run = function(harness)
      -- Mid at +250 (off-grid; plans → severed). Grandchild at +50 from
      -- mid + pitch +1 (= 62 distinct from mid's 61). Pre-quantize
      -- grandchild ppq = 250 + 50 = 300 (on-grid → not planned, stays
      -- attached). Post-rebuild the walker re-emits grandchild against
      -- the promoted mid's new ppqL=240 → 240+50=290 — descendants
      -- follow the quantized root.
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {
                { id = '1',
                  xform = { ppqL = {{'add', 50}}, pitch = {{'add', 1}},
                            vel = {{'add', 5}} },
                  children = {} },
              }},
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes = h.fm:dump().notes
      local promoted
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted)
      t.eq(promoted.ppq,   240, 'mid raw ppq snapped to row 4')
      t.eq(promoted.pitch,  61)
      t.eq(#promoted.aliases, 1, 'grandchild spec carried over')

      local gks = byParent(notes, promoted.uuid)
      t.eq(#gks, 1)
      t.eq(gks[1].ppq,   290, 'grandchild follows promoted root: 240 + 50')
      t.eq(gks[1].pitch,  62, 'pitch composes (61 + 1)')
      t.eq(gks[1].vel,   105)
      t.eq(gks[1].specPath, '1', 'specPath now relative to promoted root')
    end,
  },

  --------------------------------------------------------------------
  -- quantizeKeepRealised: aliased child severs; intent ppq snaps to
  -- row; delay absorbs the inverse to preserve realised onset.
  --------------------------------------------------------------------
  {
    name = 'quantizeKeepRealised on aliased child: severs; delay preserves realised onset',
    run = function(harness)
      -- Resolved ppq = 250, delay = 0 → realised = 250. Snap ppqL to
      -- row 4 → 240; delay must absorb +10 ppq so realised stays 250.
      local h = harness.mk(util.assign({
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      h.vm:quantizeKeepRealisedAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.deepEq(oldRoot.aliases, {}, 'severed')

      local promoted
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted)
      t.eq(promoted.ppqL, 240, 'intent ppq snapped to row 4')
      -- Realised = ppqL + delayToPPQ(delay). assignNote stores ppq as
      -- realised raw onset (= ppqL + delay-PPQ); preserved at 250.
      t.eq(promoted.ppq, 250, 'realised onset preserved')
    end,
  },
}
