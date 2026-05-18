-- Pure legato primitive. Frame-agnostic: it reads only `.ppq`/`.endppq`
-- and knows nothing of tracker columns, group frames, swing or REAPER.
-- One operation, `place`: the legato neighbours of a new onset and the
-- tail it should take (next onset in its column, else `fallback`).
-- `notes` is a column's events in ppq order, same lane/chan; the caller
-- pre-filters anything that is not a note (PAs, value events). tv calls
-- this from placeNewNote. Deleting a blocker grows no predecessor here:
-- tm's universal tail pass re-derives every realised note-off each
-- rebuild, so a vanished blocker is regrown there, not fixed up.

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

return legato
