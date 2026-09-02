-- The pass's fx windows: one half-open logical span per host, the streams it claims, and the
-- lookups over the set. See docs/trackerManager.md § Fx window census for the model.

--invariant: stateless module -- a set holds its own state, and the record mint is pure
--invariant: a window's span is logical; a raw answer converts it through the pass's time context
--shape: window = { uuid, chan, ppq, endppq, targets = { ['note'|'pb'|ccNum] = true }, [fx], [hostType] }
--shape: per-target entry = { evType, chan, [cc], id = the window's uuid, ppq, endppq }

local util = require 'util'

local fxWindows = {}

-- A note host (on-take or parked) as its degenerate window (note-is-a-region).
--post: fresh result spans the host's own onset to endppq, carrying its uuid, channel and chain
function fxWindows.fromNote(host, endppq)
  return { uuid = host.uuid, chan = host.chan, ppq = host.ppq,
           endppq = endppq, fx = host.fx, hostType = 'note' }
end

-- One window split per stream it parks: the serialised form, carrying the host's uuid as `id`.
--post: fresh result runs note, then pb, then cc ascending
local function perTargetWindows(window)
  local ccs, entries = {}, {}
  for target in pairs(window.targets) do
    if type(target) == 'number' then util.add(ccs, target) end
  end
  table.sort(ccs)
  local function entry(evType, cc)
    util.add(entries, { evType = evType, chan = window.chan, cc = cc, id = window.uuid,
                        ppq = window.ppq, endppq = window.endppq })
  end
  if window.targets.note then entry('note') end
  if window.targets.pb   then entry('pb') end
  for _, cc in ipairs(ccs) do entry('cc', cc) end
  return entries
end

-- A set of fx windows, however it was populated -- minted from the pass's hosts, or replayed from
-- the take's stored list.
--shape: doors -> windows() | window(uuid) | on(chan) | perTarget([window]) | rawSpan(window)
--shape: doors -> owns(evType, chan, cc, ppqL) | ownsRaw(evType, chan, cc, ppq)
--pre: time is the pass's projection; an empty set may omit it, since the raw doors alone read it
--post: live result = the doors over `windows`, which the set holds by reference
function fxWindows.new(windows, time)
  local byUuid, byChan, targetList, rawSpans = {}, {}, nil, {}
  for _, window in ipairs(windows) do
    byUuid[window.uuid] = window
    util.bucket(byChan, window.chan, window)
  end

  local doors = {}
  function doors.windows()    return windows end
  function doors.window(uuid) return byUuid[uuid] end
  function doors.on(chan)     return byChan[chan] or {} end

  -- Realisation-frame bounds, cached on first ask (docs/trackerManager.md § Fx window census).
  function doors.rawSpan(window)
    local span = rawSpans[window]
    if not span then
      span = { time:fromLogical(window.chan, window.ppq), time:fromLogical(window.chan, window.endppq) }
      rawSpans[window] = span
    end
    return span[1], span[2]
  end

  -- Half-open containment on every stream, which is also how parking reads a note: the note is taken
  -- when its onset falls inside, so onset-in-span is the one test.
  local function covering(evType, chan, cc, ppq, raw)
    for _, window in ipairs(byChan[chan] or {}) do
      if window.targets[evType == 'cc' and cc or evType] then
        local startppq, endppq = window.ppq, window.endppq
        if raw then startppq, endppq = doors.rawSpan(window) end
        if ppq >= startppq and ppq < endppq then return window.uuid end
      end
    end
  end
  --post: result = the uuid of the window covering that event on that stream, nil if none does
  function doors.owns(evType, chan, cc, ppqL)   return covering(evType, chan, cc, ppqL, false) end
  -- The same walk in the realisation frame, for the questions asked of mm records: convert the
  -- bounds once, compare raw to raw. see docs/generators.md § Route-by-window
  --post: result = the uuid of the window covering that raw onset on that stream, nil if none does
  function doors.ownsRaw(evType, chan, cc, ppq) return covering(evType, chan, cc, ppq, true) end

  -- The serialised view, minted once: `fxRealisedWindows` persists it and diffs it by value, so the
  -- order is the target's own and not the order the chain's stages were authored in.
  --post: (window given) → fresh entries; else the whole set's, in window order
  function doors.perTarget(window)
    if window then return perTargetWindows(window) end
    if targetList then return targetList end
    targetList = {}
    for _, held in ipairs(windows) do
      for _, entry in ipairs(perTargetWindows(held)) do util.add(targetList, entry) end
    end
    return targetList
  end
  return doors
end

return fxWindows
