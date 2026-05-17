-- Pure legato primitive. Frame-agnostic: it reads only `.ppq`/`.endppq`
-- and knows nothing of tracker columns, group frames, swing or REAPER.
-- One invariant — a note's tail runs to the next onset in its column —
-- expressed two ways the editing layers need:
--
--   place        — the legato neighbours of a new onset, and the tail
--                   it should take (next onset, else `fallback`).
--   deleteFixups  — deleting notes that legato-owned a run grows each
--                   surviving predecessor over the gap to the next
--                   survivor's onset (or `fallback` past the last).
--
-- `notes` is a column's events in ppq order, same lane/chan; callers
-- pre-filter anything that is not a note (PAs, value events). tv calls
-- this from placeNewNote / queueDeleteNotes; gm from group-frame
-- Step 1 and the Step 2 manifest. Shared so the two cannot drift.

local util = require 'util'

local legato = {}

-- (predecessor, successor, tail) for an onset at `ppq`. The predecessor
-- is the note the new onset hands off from; the successor the one it
-- hands off to; the tail is the successor's onset, or `fallback` when
-- nothing follows. The caller decides whether to clip the predecessor
-- (it does iff `prev.endppq >= ppq`) — that one-liner stays at the call
-- site in each frame's own mutation idiom.
function legato.place(notes, ppq, fallback)
  local prev = util.seek(notes, 'before', ppq, util.isNote)
  local nxt  = util.seek(notes, 'after',  ppq, util.isNote)
  return prev, nxt, nxt and nxt.ppq or fallback
end

-- Removing every note in `deleted` (an [evt]=truthy set) from the
-- ordered column `notes`: when a deleted run leaves a hole, the
-- surviving note that was legato-running into it grows to swallow the
-- hole — its tail moves to the next survivor's onset, or `fallback`
-- past the last. A consecutive run of deletes is bridged by a single
-- fixup. Returns { { evt = <surviving note whose tail grows>,
-- endppq = <new tail> }... }; the caller applies them after deleting (a
-- same-key clamp reads live state, so delete-first / stretch-second).
function legato.deleteFixups(notes, deleted, fallback)
  local fixups, lastSurvivor, pending = {}, nil, false
  for _, evt in ipairs(notes) do
    if deleted[evt] then
      if not pending and lastSurvivor and lastSurvivor.endppq >= evt.ppq then
        pending = true
      end
    else
      if pending then util.add(fixups, { evt = lastSurvivor, endppq = evt.ppq }) end
      pending, lastSurvivor = false, evt
    end
  end
  if pending then util.add(fixups, { evt = lastSurvivor, endppq = fallback }) end
  return fixups
end

return legato
