-- Half-open span sets: { lo, hi } intervals coalesced, clipped and subtracted, plus the two adaptors
-- that read a window off a record so a caller can pass its bucket of them.

--invariant: stateless module: pure functions over spans, no module-level state
--invariant: a span is half-open [lo, hi): merge joins at a touch, overlapping and intersects do not
--invariant: every span returned is freshly built, so no caller's span is aliased into a result
--shape: span = { lo, hi }; span set = disjoint ascending spans; bucket = records carrying .window = span
local util = require 'util'

local spans = {}

-- Coalesce { lo, hi } spans into maximal disjoint ascending ones: overlap and adjacency join, gaps
-- split. Copies as it goes, so no input span is aliased into the result.
function spans.merge(list)
  local sorted = {}
  for _, s in ipairs(list) do util.add(sorted, { s[1], s[2] }) end
  table.sort(sorted, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, s in ipairs(sorted) do
    local last = merged[#merged]
    if last and s[1] <= last[2] then last[2] = math.max(last[2], s[2])
    else util.add(merged, { s[1], s[2] }) end
  end
  return merged
end

-- Merge a bucket's windows into maximal covered spans; and pick the members covering a span.
-- Shared by cc- and pb-augment summation.
function spans.mergeWindows(bucket)
  local wins = {}
  for _, m in ipairs(bucket) do util.add(wins, m.window) end
  return spans.merge(wins)
end
function spans.overlapping(bucket, span)
  local out = {}
  for _, m in ipairs(bucket) do
    if m.window[1] < span[2] and m.window[2] > span[1] then util.add(out, m) end
  end
  return out
end

-- Half-open span-set intersection over merged scopes (nil scopes = empty).
function spans.intersects(scopes, window)
  for _, span in ipairs(scopes or {}) do
    if window[1] < span[2] and window[2] > span[1] then return true end
  end
  return false
end
function spans.clip(span, scopes)
  local clipped = {}
  for _, scope in ipairs(scopes or {}) do
    local lo, hi = math.max(span[1], scope[1]), math.min(span[2], scope[2])
    if lo < hi then util.add(clipped, { lo, hi }) end
  end
  return clipped
end
-- Complement of spans.clip within `span` (`scopes` sorted and disjoint: mergeWindows output).
function spans.subtract(span, scopes)
  local rest, cursor = {}, span[1]
  for _, scope in ipairs(scopes or {}) do
    local lo, hi = math.max(span[1], scope[1]), math.min(span[2], scope[2])
    if lo < hi then
      if cursor < lo then util.add(rest, { cursor, lo }) end
      cursor = hi
    end
  end
  if cursor < span[2] then util.add(rest, { cursor, span[2] }) end
  return rest
end

return spans
