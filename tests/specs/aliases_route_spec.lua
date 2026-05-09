-- Phase 3: edit routing. Relative nudges on aliased children compose
-- into the spec's per-field op-list (with coalescence on literal-arg
-- adds); plain events keep the pre-aliases mutation path.

local t = require('support')

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, uuid = 1 }
  for k, v in pairs(extras) do n[k] = v end
  return n
end

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

return {
  --------------------------------------------------------------------
  -- Aliased child: pitch op-list grows from empty to one entry
  --------------------------------------------------------------------
  {
    name = 'aliased pitch nudge appends to empty op-list; root unchanged',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)
      h.cmgr:invoke('nudgeFineUp')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.truthy(root, 'root present')
      t.deepEq(root.aliases[1].xform.pitch, {{'add', 1}})
      t.deepEq(root.aliases[1].xform.ppqL,  {{'add', 240}}, 'ppqL op untouched')
      t.eq(root.pitch, 60, 'root pitch unchanged')
    end,
  },

  --------------------------------------------------------------------
  -- Plain event: identical to today
  --------------------------------------------------------------------
  {
    name = 'plain pitch nudge mutates the note directly; no aliases written',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { {
          ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
          detune = 0, delay = 0,
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('nudgeFineUp')

      local notes = h.fm:dump().notes
      t.eq(#notes, 1)
      t.eq(notes[1].pitch, 61)
      t.falsy(notes[1].aliases)
    end,
  },

  --------------------------------------------------------------------
  -- Two same-direction nudges land as a single coalesced trailing add
  --------------------------------------------------------------------
  {
    name = 'two same-direction nudges coalesce into one trailing add',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)
      h.cmgr:invoke('nudgeFineUp')
      h.cmgr:invoke('nudgeFineUp')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.deepEq(root.aliases[1].xform.pitch, {{'add', 2}},
               'single coalesced trailing add')
    end,
  },

  --------------------------------------------------------------------
  -- A nudge after a `{add, {rand,...}}` appends fresh; rand entry intact
  --------------------------------------------------------------------
  {
    name = 'nudge after rand-arg op appends fresh, does not mutate rand entry',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL  = {{'add', 240}},
                        pitch = {{'add', {'rand', 0, 1}}} },
              children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)
      h.cmgr:invoke('nudgeFineUp')

      local root  = rootByUuid(h.fm:dump().notes, 1)
      local pitch = root.aliases[1].xform.pitch
      t.eq(#pitch, 2, 'op list grew to 2 entries')
      t.deepEq(pitch[1], {'add', {'rand', 0, 1}}, 'rand entry intact')
      t.deepEq(pitch[2], {'add', 1},              'fresh add appended')
    end,
  },
}
