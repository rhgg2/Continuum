-- Phase 5.4: typed pitch on an aliased child re-relativises into a step
-- delta on the spec node's pitch field. The materialised event is NOT
-- severed — the spec absorbs the change. Under temper, the delta is
-- computed in tuning steps (step + oct*octaveStep), not MIDI semitones.

local t = require('support')
local tuning = require('tuning')

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

-- qwerty row 1: z s x d c v g b h n j m , l .  (semis 0..14, octOff 0)
-- 'b' = G  (semi 7),  'x' = D  (semi 2),  'z' = C (semi 0)
local CFG = { take = { rowPerBeat = 1, currentOctave = 4, noteLayout = 'qwerty' } }

return {
  --------------------------------------------------------------------
  -- Typed note name on an aliased child appends a step delta into the
  -- spec node's pitch op-list and coalesces with the trailing add.
  --------------------------------------------------------------------
  {
    name = 'typed pitch on aliased child appends step delta; coalesces with prior add',
    run = function(harness)
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)

      local kid = aliasKid(h.fm:dump().notes, 1)
      t.truthy(kid,                 'alias materialised')
      t.eq(kid.pitch, 61,           'resolved pitch = 60 + 1 step (no temper → semitone)')

      -- Locate the column holding the alias at row 1.
      local col, rowEvt
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.cells and c.cells[1]
           and c.cells[1].parentUuid == 1 then
          col, rowEvt = c, c.cells[1]; break
        end
      end
      t.truthy(col, 'alias visible in some grid col at row 1')

      h.ec:setPos(1, 1, 1)  -- stop 1 = first pitch char
      -- Use the col-side ref (carries parentUuid + specPath).
      h.vm:editEvent(col, rowEvt, 1, string.byte('b'), false)

      local root = rootByUuid(h.fm:dump().notes, 1)
      -- δ = 67 - 61 = 6; coalesces {{'add', 1}, {'add', 6}} → {{'add', 7}}.
      t.deepEq(root.children[1].xform.pitch, {{'add', 7}})
      t.eq(root.pitch, 60,           'root pitch unchanged')

      local kid2 = aliasKid(h.fm:dump().notes, 1)
      t.truthy(kid2,                 'still aliased — no sever')
      t.eq(kid2.pitch, 67,           'resolved pitch follows new step delta')
    end,
  },

  --------------------------------------------------------------------
  -- Octave-digit input on an aliased child also routes a pitch step
  -- delta (whole-octave shift = octaveStep steps).
  --------------------------------------------------------------------
  {
    name = 'typed octave digit on aliased child routes a pitch-step delta',
    run = function(harness)
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)

      local col, rowEvt
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.cells and c.cells[1]
           and c.cells[1].parentUuid == 1 then
          col, rowEvt = c, c.cells[1]; break
        end
      end

      h.ec:setPos(1, 1, 2)  -- stop 2 = octave digit
      -- '5': newPitch = (5+1)*12 + 61%12 = 73; δ = 73 - 61 = 12.
      h.vm:editEvent(col, rowEvt, 2, string.byte('5'), false)

      local root = rootByUuid(h.fm:dump().notes, 1)
      -- Coalesces {{'add', 1}, {'add', 12}} → {{'add', 13}}.
      t.deepEq(root.children[1].xform.pitch, {{'add', 13}})

      local kid = aliasKid(h.fm:dump().notes, 1)
      t.eq(kid.pitch, 73,            'resolved pitch jumped one octave + one step')
    end,
  },

  --------------------------------------------------------------------
  -- Plain (non-aliased) note: existing path. Direct assign, no alias
  -- machinery touched.
  --------------------------------------------------------------------
  {
    name = 'typed pitch on plain note bypasses alias routing (regression)',
    run = function(harness)
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{} } },  -- root only, no aliases
      }
      h.vm:setGridSize(80, 40)
      local col = h.vm.grid.cols[1]
      local evt = col.cells[0]
      t.truthy(evt)

      h.ec:setPos(0, 1, 1)
      -- 'x' = D (semi 2); newPitch = 5*12 + 2 = 62.
      h.vm:editEvent(col, evt, 1, string.byte('x'), false)

      local notes = h.fm:dump().notes
      t.eq(#notes, 1)
      t.eq(notes[1].pitch, 62)
      t.falsy(notes[1].children, 'no alias spec written')
    end,
  },

  --------------------------------------------------------------------
  -- Under temper, the routed delta is in TUNING steps. With 19EDO and
  -- root pitch 60: typing 'x' (MIDI D=62) snaps to step 4, oct 4 (MIDI
  -- 62, detune -11). The alias starts on step 1, oct 4. δ = 3 steps.
  --------------------------------------------------------------------
  {
    name = 'under 19EDO: typed pitch routes a temper-step delta (not semitones)',
    run = function(harness)
      local TEMPER_19 = tuning.presets['19EDO']
      local h = harness.mk{
        config = {
          take    = { currentOctave = 4, noteLayout = 'qwerty' },
          track   = { rowPerBeat = 1, temper = '19EDO' },
          project = { tempers = { ['19EDO'] = TEMPER_19 } },
        },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)

      local kid = aliasKid(h.fm:dump().notes, 1)
      t.eq(kid.pitch,  60,  'alias resolves to root pitch (zero step delta)')
      t.eq(kid.detune, 0)

      local col, rowEvt
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.cells and c.cells[1]
           and c.cells[1].parentUuid == 1 then
          col, rowEvt = c, c.cells[1]; break
        end
      end
      t.truthy(col)

      h.ec:setPos(1, 1, 1)
      h.vm:editEvent(col, rowEvt, 1, string.byte('x'), false)

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.children[1].xform.pitch, {{'add', 3}},
               '19EDO step delta from C to D (step 1 → step 4)')

      local kid2 = aliasKid(h.fm:dump().notes, 1)
      local expP, expD = tuning.transposeStep(TEMPER_19, 60, 0, 3)
      t.eq(kid2.pitch,  expP, 'resolved pitch via transposeStep(+3)')
      t.eq(kid2.detune, expD)
    end,
  },

  --------------------------------------------------------------------
  -- Typing the pitch already resolved is a no-op: δ = 0, spec untouched.
  --------------------------------------------------------------------
  {
    name = 'typed pitch matching resolved is a no-op: spec unchanged',
    run = function(harness)
      local h = harness.mk{
        config = CFG,
        seed = { notes = { rootNote{
          aliasCtr = 2,
          children = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local col, rowEvt
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.cells and c.cells[1]
           and c.cells[1].parentUuid == 1 then
          col, rowEvt = c, c.cells[1]; break
        end
      end

      h.ec:setPos(1, 1, 1)
      -- 's' = C# (semi 1); newPitch = 5*12 + 1 = 61; δ = 0.
      h.vm:editEvent(col, rowEvt, 1, string.byte('s'), false)

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.children[1].xform.pitch, {{'add', 1}}, 'no zero-delta append')
    end,
  },
}
