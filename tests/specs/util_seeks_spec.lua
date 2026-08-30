-- The two index seeks hoisted out of trackerManager into util. Both bisect a
-- ppq-sorted list and return an *index*, where util.seek scans and returns an
-- item: util.firstAfter answers the first index whose .ppq exceeds the target,
-- util.firstAtOrAfter the first index at or past it. When nothing qualifies
-- both answer #list + 1, and callers lean on that -- `firstAfter(list, ppq) - 1`
-- is the idiom for "the last index at or before ppq", answering 0 when there is
-- none. A run of equal ppq is where the two part company, which is why both
-- names exist.

local t = require('support')
local util = require('util')

local function ppqList(...)
  local out = {}
  for _, ppq in ipairs({ ... }) do util.add(out, { ppq = ppq }) end
  return out
end

-- Linear oracles, independent of the bisection under test.
local function scanAfter(list, target)
  for i, e in ipairs(list) do if e.ppq > target then return i end end
  return #list + 1
end
local function scanAtOrAfter(list, target)
  for i, e in ipairs(list) do if e.ppq >= target then return i end end
  return #list + 1
end

return {
  {
    name = 'seeks: an empty list answers index 1 -- one past its end',
    run = function()
      local empty = {}
      t.eq(util.firstAfter(empty, 0), 1)
      t.eq(util.firstAtOrAfter(empty, 0), 1)
    end,
  },
  {
    -- The two boundaries. Below the first onset everything qualifies, so both
    -- answer 1; above the last nothing does, so both answer one past the end.
    name = 'seeks: below the first onset both answer 1, above the last both answer past the end',
    run = function()
      local list = ppqList(240, 480, 960)
      t.eq(util.firstAfter(list, 0), 1)
      t.eq(util.firstAtOrAfter(list, 0), 1)
      t.eq(util.firstAfter(list, 1920), #list + 1)
      t.eq(util.firstAtOrAfter(list, 1920), #list + 1)
    end,
  },
  {
    -- On an exact onset the names diverge: at-or-after includes it, after steps
    -- over it. Every other target agrees.
    name = 'seeks: on an exact onset at-or-after lands on it, after steps past',
    run = function()
      local list = ppqList(0, 240, 480)
      t.eq(util.firstAtOrAfter(list, 240), 2)
      t.eq(util.firstAfter(list, 240), 3)
      t.eq(util.firstAtOrAfter(list, 120), 2)
      t.eq(util.firstAfter(list, 120), 2)
    end,
  },
  {
    -- A run of equal ppq is straddled: at-or-after opens the run, after closes
    -- it, and the difference is the run's length. Bisection makes this the one
    -- case where a naive implementation lands mid-run.
    name = 'seeks: a run of equal ppq is straddled -- at-or-after opens it, after closes it',
    run = function()
      local list = ppqList(0, 240, 240, 240, 480)
      t.eq(util.firstAtOrAfter(list, 240), 2)
      t.eq(util.firstAfter(list, 240), 5)
    end,
  },
  {
    -- The caller-side idiom. tm reads `firstAfter(list, ppq) - 1` as the last
    -- element at or before ppq -- the one governing that moment -- and index 0
    -- as "nothing governs it yet".
    name = 'seeks: firstAfter minus one is the last index at or before, and 0 when there is none',
    run = function()
      local list = ppqList(0, 240, 480)
      t.eq(list[util.firstAfter(list, 100) - 1].ppq, 0)
      t.eq(list[util.firstAfter(list, 240) - 1].ppq, 240)
      t.eq(list[util.firstAfter(list, 9999) - 1].ppq, 480)
      t.eq(util.firstAfter(list, -1) - 1, 0)
      t.eq(list[0], nil)
    end,
  },
  {
    -- The bisection against a linear scan over every target in and around the
    -- list, including the ties and the gaps. The guards keep the sweep from
    -- passing vacuously: it must actually cross a run where the two disagree,
    -- and must reach past the end.
    name = 'seeks: the bisection agrees with a linear scan across a sweep of targets',
    run = function()
      local list = ppqList(0, 240, 240, 240, 480, 960)
      local straddles, pastEnd = 0, 0
      for target = -10, 1000 do
        local after, atOrAfter = util.firstAfter(list, target), util.firstAtOrAfter(list, target)
        t.eq(after, scanAfter(list, target), 'firstAfter at ' .. target)
        t.eq(atOrAfter, scanAtOrAfter(list, target), 'firstAtOrAfter at ' .. target)
        if after - atOrAfter > 1 then straddles = straddles + 1 end
        if after == #list + 1 then pastEnd = pastEnd + 1 end
      end
      t.truthy(straddles > 0, 'sweep never crossed a run of equal ppq')
      t.truthy(pastEnd > 0, 'sweep never ran past the end of the list')
    end,
  },
}
