-- Pure mirror core. project(head, inst) -> desired, conflicts, states:
-- resolves a head template plus an instance's override/locals/drops state
-- into the events the instance should contain, local-wins, flagging a
-- conflict where an override's captured base has drifted from the live head.
-- reconcile(desired, current) diffs by vuid into minimal add/del/set ops --
-- a move or resize is one `set`, never del+add. deriveOverride captures the
-- merge base at fork time. streamId/inRect are the region membership
-- primitives: identity-by-(evType+key), not by view-column index.
--
-- Templates are flat, field-agnostic, head-relative (pasteMulti vocabulary:
-- chanDelta/key/ppq/dur). The core never interprets a field. No REAPER, no
-- anchor maths -- that belongs to the stateful mirrorManager wrapper.

local t      = require('support')
local mirror = require('mirror')

local function note(ppq, extra)
  local n = { evType = 'note', chanDelta = 0, key = 0, ppq = ppq, dur = 240, pitch = 60, vel = 100 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- Wrap an events table in a head. project() only reads head.events; the
-- rect is the stateful layer's membership predicate, exercised separately
-- by the streamId/inRect tests below.
local function hd(events)
  return { rect = { ppq = 0, dur = 960, chanLo = 1, streams = { [0] = { ['note:0'] = true } } },
           events = events }
end

return {
  ---------- project: clean propagation

  {
    name = 'no overrides -> every head event synced, no conflicts',
    run = function()
      local head = hd({ [1] = note(0), [2] = note(960, { pitch = 64 }) })
      local desired, conflicts, states = mirror.project(head, {})
      t.deepEq(conflicts, {})
      t.eq(states[1], 'synced')
      t.eq(states[2], 'synced')
      t.eq(desired[2].pitch, 64)
      t.eq(desired[1].evType, 'note')
      t.falsy(desired[1].state, 'payload must not carry provenance')
    end,
  },

  {
    name = 'dropped head event is absent from desired',
    run = function()
      local head = hd({ [1] = note(0), [2] = note(960) })
      local desired = mirror.project(head, { deletes = { [2] = true } })
      t.truthy(desired[1])
      t.falsy(desired[2])
    end,
  },

  {
    name = 'a local add is an override (no separate "local" state)',
    run = function()
      local head = hd({ [1] = note(0) })
      local _, _, states = mirror.project(head, { adds = { [99] = note(1920, { pitch = 72 }) } })
      t.eq(states[99], 'overridden')
    end,
  },

  ---------- project: overrides (sticky local-wins) + conflict flag

  {
    name = 'clean override: base matches head -> local wins, no conflict',
    run = function()
      local head = hd({ [1] = note(0, { pitch = 60 }) })
      local inst = { assigns = { [1] = { pitch = { base = 60, value = 72 } } } }
      local desired, conflicts, states = mirror.project(head, inst)
      t.eq(desired[1].pitch, 72)
      t.eq(states[1], 'overridden')
      t.deepEq(conflicts, {})
    end,
  },

  {
    name = 'a drifted base is NOT a conflict: local still wins, no flag',
    run = function()
      local head = hd({ [1] = note(0, { pitch = 67 }) })            -- head moved 60->67
      local inst = { assigns = { [1] = { pitch = { base = 60, value = 72 } } } }
      local desired, conflicts, states = mirror.project(head, inst)
      t.eq(desired[1].pitch, 72)                                     -- sticky: local wins
      t.eq(states[1], 'overridden')                                  -- drift no longer conflicts
      t.deepEq(conflicts, {})
    end,
  },

  {
    name = 'orthogonal override: head edits a different field, no conflict, both apply',
    run = function()
      local head = hd({ [1] = note(0, { pitch = 67 }) })             -- head changed pitch; vel still 100
      local inst = { assigns = { [1] = { vel = { base = 100, value = 40 } } } }
      local desired, conflicts = mirror.project(head, inst)
      t.eq(desired[1].pitch, 67)                                     -- head pitch propagates
      t.eq(desired[1].vel, 40)                                       -- local vel sticks (base==head, clean)
      t.deepEq(conflicts, {})
    end,
  },

  {
    name = 'move is a ppq override; resize is a dur override; each one override',
    run = function()
      local head = hd({ [1] = note(0) })
      local inst = { assigns = { [1] = {
        ppq = { base = 0,   value = 1440 },
        dur = { base = 240, value = 480  },
      } } }
      local desired, conflicts = mirror.project(head, inst)
      t.eq(desired[1].ppq, 1440)
      t.eq(desired[1].dur, 480)
      t.deepEq(conflicts, {})
    end,
  },

  {
    name = 'channel/lane shift is a chanDelta/key override like any field',
    run = function()
      local head = hd({ [1] = note(0) })
      local inst = { assigns = { [1] = { chanDelta = { base = 0, value = 2 }, key = { base = 0, value = 1 } } } }
      local desired = mirror.project(head, inst)
      t.eq(desired[1].chanDelta, 2)
      t.eq(desired[1].key, 1)
    end,
  },

  {
    name = 'assign whose group event vanished is dropped (group is the authority)',
    run = function()
      local head = hd({})                                            -- head no longer has vuid 1
      local inst = { assigns = { [1] = { pitch = { base = 60, value = 72 } } } }
      local desired, conflicts, states = mirror.project(head, inst)
      t.falsy(desired[1], 'the orphaned override is not resurrected')
      t.eq(states[1], nil)
      t.deepEq(conflicts, {})
    end,
  },

  ---------- project: legato replay (the mirror replay model)

  {
    name = 'delete extends the legato predecessor over the hole',
    run = function()
      -- A B C D, each legato into the next (end == next onset).
      local head = hd({
        [1] = note(0,   { dur = 240 }),
        [2] = note(240, { dur = 240 }),
        [3] = note(480, { dur = 240 }),
        [4] = note(720, { dur = 240 }),
      })
      local desired = mirror.project(head, { deletes = { [3] = true } })
      t.falsy(desired[3], 'C is gone')
      t.eq(desired[2].dur, 480, 'B legato-owned C -> grows to D onset (720-240)')
      t.eq(desired[1].dur, 240, 'A untouched (gap-free, not the owner of the hole)')
      t.eq(desired[4].dur, 240, 'D, last in lane, keeps its own dur')
    end,
  },

  {
    name = 'a gap before the deleted note means the predecessor does not grow',
    run = function()
      local head = hd({
        [1] = note(0,   { dur = 120 }),  -- ends at 120, gap before C
        [3] = note(480, { dur = 240 }),
      })
      local desired = mirror.project(head, { deletes = { [3] = true } })
      t.eq(desired[1].dur, 120, 'A did not legato-own C -> unchanged')
    end,
  },

  {
    name = 'an override add clips the template note it lands inside (legato handoff)',
    run = function()
      local head = hd({ [1] = note(0, { dur = 480 }) })  -- overruns to 480
      local add  = { evType = 'note', chanDelta = 0, key = 0, ppq = 240,
                     pitch = 60, vel = 100 }              -- no dur (a bare insert)
      local desired, _, states = mirror.project(head, { adds = { [99] = add } })
      t.eq(desired[1].dur, 240, 'template clipped to the add onset')
      t.eq(desired[99].ppq, 240)
      t.eq(states[99], 'overridden')
    end,
  },

  {
    name = 'add onto an occupied (lane, onset) is skipped and conflicted',
    run = function()
      local head = hd({ [1] = note(0, { dur = 240 }) })
      local add  = { evType = 'note', chanDelta = 0, key = 0, ppq = 0,
                     pitch = 64, vel = 100 }
      local desired, conflicts, states = mirror.project(head, { adds = { [99] = add } })
      t.truthy(desired[1], 'the lower vuid keeps the slot')
      t.falsy(desired[99], 'the colliding add is skipped')
      t.eq(states[99], 'conflicted')
      t.truthy(conflicts[99])
    end,
  },

  {
    name = 'an assign that moves a note onto a sibling onset collides and is skipped',
    run = function()
      local head = hd({ [1] = note(0, { dur = 240 }), [2] = note(480, { dur = 240 }) })
      local inst = { assigns = { [2] = { ppq = { base = 480, value = 0 } } } }
      local desired, _, states = mirror.project(head, inst)
      t.truthy(desired[1])
      t.falsy(desired[2], 'moved-onto-occupied is skipped')
      t.eq(states[2], 'conflicted')
    end,
  },

  {
    name = 'the last note in a lane is clipped to the pattern length (conform)',
    run = function()
      local head = hd({ [1] = note(0, { dur = 2000 }) })   -- overruns the take
      local desired = mirror.project(head, {}, 960)
      t.eq(desired[1].dur, 960, 'trailing note clipped to patternLen')
    end,
  },

  {
    name = 'a short trailing note is not extended -- clip only, never grow',
    run = function()
      local head = hd({ [1] = note(0, { dur = 120 }) })
      local desired = mirror.project(head, {}, 960)
      t.eq(desired[1].dur, 120, 'staccato at the end stays short')
    end,
  },

  {
    name = 'a note overrunning its next realised neighbour is clipped to that onset',
    run = function()
      local head = hd({ [1] = note(0, { dur = 900 }), [2] = note(480, { dur = 240 }) })
      local desired = mirror.project(head, {}, 4000)
      t.eq(desired[1].dur, 480, 'clipped to the next note in the realised lane')
      t.eq(desired[2].dur, 240, 'last note keeps its own (shorter) dur')
    end,
  },

  {
    name = 'project is idempotent and does not mutate the group',
    run = function()
      local head = hd({ [1] = note(0, { dur = 480 }), [2] = note(240, { dur = 240 }) })
      local d1 = mirror.project(head, {})
      local d2 = mirror.project(head, {})
      t.deepEq(d1, d2, 'same inputs -> same desired set')
      t.eq(head.events[1].dur, 480, 'group event dur untouched by projection')
    end,
  },

  ---------- reconcile: minimal ops by vuid

  {
    name = 'add when desired has a vuid current lacks',
    run = function()
      local ops = mirror.reconcile({ [1] = note(0) }, {})
      t.eq(#ops, 1)
      t.eq(ops[1].op, 'add')
      t.eq(ops[1].vuid, 1)
    end,
  },

  {
    name = 'del when current has a vuid desired lacks',
    run = function()
      local ops = mirror.reconcile({}, { [1] = { uuid = 555, groupEvt = note(0) } })
      t.eq(#ops, 1)
      t.eq(ops[1].op, 'del')
      t.eq(ops[1].uuid, 555)
    end,
  },

  {
    name = 'move emits a single set, never del+add',
    run = function()
      local desired = { [1] = note(1440) }                           -- moved 0 -> 1440
      local current = { [1] = { uuid = 555, groupEvt = note(0) } }
      local ops = mirror.reconcile(desired, current)
      t.eq(#ops, 1)
      t.eq(ops[1].op, 'set')
      t.eq(ops[1].uuid, 555)
      t.eq(ops[1].groupEvt.ppq, 1440)
    end,
  },

  {
    name = 'unchanged vuid emits no op',
    run = function()
      local current = { [1] = { uuid = 555, groupEvt = note(0) } }
      t.eq(#mirror.reconcile({ [1] = note(0) }, current), 0)
    end,
  },

  ---------- deriveAssign: base capture at fork

  {
    name = 'deriveAssign captures live head value as base',
    run = function()
      t.deepEq(mirror.deriveAssign(note(0, { pitch = 62 }), 'pitch', 71), { base = 62, value = 71 })
    end,
  },

  {
    name = 'deriveAssign on a local-only (no head template) captures nil base',
    run = function()
      t.deepEq(mirror.deriveAssign(nil, 'pitch', 71), { base = nil, value = 71 })
    end,
  },

  ---------- streamId: index-free per-stream identity

  {
    name = 'streamId is evType:key -- distinguishes lanes and cc numbers, ignores column position',
    run = function()
      t.eq(mirror.streamId({ evType = 'note', key = 0 }), 'note:0')
      t.eq(mirror.streamId({ evType = 'note', key = 2 }), 'note:2')
      t.eq(mirror.streamId({ evType = 'cc',   key = 74 }), 'cc:74')
      t.eq(mirror.streamId({ evType = 'pb' }), 'pb:0')                -- no key -> 0
      t.truthy(mirror.streamId({ evType = 'cc', key = 1 })
            ~= mirror.streamId({ evType = 'cc', key = 74 }))
    end,
  },

  ---------- inRect: region membership predicate

  {
    name = 'inRect true only inside the time span',
    run = function()
      local rect = { ppq = 480, dur = 480, chanLo = 1, streams = { [0] = { ['note:0'] = true } } }
      local n = note(0)
      t.falsy(mirror.inRect(rect, 479,  0, n))                       -- before span
      t.truthy(mirror.inRect(rect, 480,  0, n))                      -- span start (inclusive)
      t.truthy(mirror.inRect(rect, 959,  0, n))                      -- last ppq in span
      t.falsy(mirror.inRect(rect, 960,  0, n))                       -- span end (exclusive)
    end,
  },

  {
    name = 'inRect false for a channel offset that does not participate',
    run = function()
      local rect = { ppq = 0, dur = 960, chanLo = 1, streams = { [0] = { ['note:0'] = true } } }
      t.truthy(mirror.inRect(rect, 0, 0, note(0)))
      t.falsy(mirror.inRect(rect, 0, 1, note(0)))                    -- chanOffset 1 absent
    end,
  },

  {
    name = 'inRect false for a stream not selected on its channel -- cc-only region excludes notes',
    run = function()
      local rect = { ppq = 0, dur = 960, chanLo = 1, streams = { [0] = { ['cc:74'] = true } } }
      t.truthy(mirror.inRect(rect, 0, 0, { evType = 'cc', key = 74, ppq = 0 }))
      t.falsy(mirror.inRect(rect, 0, 0, note(0)))                    -- note:0 not selected
    end,
  },

  {
    name = 'inRect: per-channel selectors differ -- notes+cc on ch0, cc1 only on ch1',
    run = function()
      local rect = { ppq = 0, dur = 960, chanLo = 1, streams = {
        [0] = { ['note:0'] = true, ['cc:74'] = true },
        [1] = { ['cc:1'] = true },
      } }
      t.truthy(mirror.inRect(rect, 0, 0, note(0)))
      t.truthy(mirror.inRect(rect, 0, 0, { evType = 'cc', key = 74 }))
      t.falsy(mirror.inRect(rect, 0, 1, note(0)))                    -- ch1 carries no notes
      t.truthy(mirror.inRect(rect, 0, 1, { evType = 'cc', key = 1 }))
    end,
  },
}
