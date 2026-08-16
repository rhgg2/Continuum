-- The objective an adaptive-tuning solve minimises, and the strands it is taken over.
-- See design/adaptive-tuning.md § What "in tune" means. @noindex

--invariant: pure module: no state; ratios/cents are tuning.lua's, the placement carries them
--shape: Coords = {[oddPrime]=exponent}; prime 2 is absent, so the score reads harmony not spacing
--shape: Strand = { notes={ {ppq,pitch,endppq,..},.. }, class=<step-class>, shortlist={ Candidate,.. } }; the walk reads the strikes, the releases and the class
--shape: Sonority = { ppq, strands={ strandIndex,.. } }; most recently struck first, the last n struck and whatever else still sounds
--shape: Candidate = { coords=Coords, strain=<distance from the written step, in half-windows> }

local util    = require 'util'
local tuning  = require 'tuning'
local sonority = {}

----- The box

-- The axes are gathered before any is measured, so an axis no member names doesn't reach
-- back to 0; the spans are the octave-free lcm/gcd's coords, whose height tuning.height gives.
--contract: coords[] → tuning.height of the coords of the set's octave-free lcm/gcd
function sonority.score(coordSet)
  local spans = {}
  for _, coords in ipairs(coordSet) do
    for prime in pairs(coords) do spans[prime] = 0 end
  end
  for prime in pairs(spans) do
    local high, low = coordSet[1][prime] or 0, coordSet[1][prime] or 0
    for i = 2, #coordSet do
      local exponent = coordSet[i][prime] or 0
      if exponent > high then high = exponent end
      if exponent < low  then low  = exponent end
    end
    spans[prime] = high - low
  end
  return tuning.height(spans)
end

----- The strands

-- Notes of a class that overlap hold one tuning (§ The strand); the running
-- release is half-open, so a note struck at a release starts another.
--contract: notes, classOf → a Strand per class per run of overlapping notes, shortlists unfilled
--contract: grouped by ascending class, each in strike order, whatever order the notes arrive in
function sonority.strands(notes, classOf)
  local byClass, classes = {}, {}
  for _, note in ipairs(notes) do
    local class = classOf(note)
    if not byClass[class] then util.add(classes, class) end
    util.bucket(byClass, class, note)
  end
  table.sort(classes)

  local strands = {}
  for _, class in ipairs(classes) do
    local members = byClass[class]
    table.sort(members, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      return a.endppq < b.endppq
    end)
    local open, release
    for _, note in ipairs(members) do
      if open and note.ppq < release then
        util.add(open.notes, note)
        if note.endppq > release then release = note.endppq end
      else
        open, release = { notes = { note }, class = class }, note.endppq
        util.add(strands, open)
      end
    end
  end
  return strands
end

----- The walk

-- Every strike, in onset order, lowest last — so a released chord leaves its
-- bass to the sonority that follows (design/adaptive-tuning.md § The model).
local function strikesInOrder(strands)
  local strikes = {}
  for index, strand in ipairs(strands) do
    for _, note in ipairs(strand.notes) do
      util.add(strikes, { ppq = note.ppq, pitch = note.pitch, strand = index })
    end
  end
  table.sort(strikes, function(a, b)
    if a.ppq   ~= b.ppq   then return a.ppq   < b.ppq   end
    if a.pitch ~= b.pitch then return a.pitch > b.pitch end
    return a.strand < b.strand
  end)
  return strikes
end

-- Half-open, so a note released where the next is struck does not sound there,
-- and a passage whose notes stop as the next begin reads as the last n struck.
local function sounding(strand, ppq)
  for _, note in ipairs(strand.notes) do
    if note.ppq <= ppq and ppq < note.endppq then return true end
  end
  return false
end

-- The class holds one entry however many notes write it: a restrike moves its
-- own entry to the front, and a second strand of the class takes the entry over.
local function promote(recent, strands, index)
  local class = strands[index].class
  for k = 1, #recent do
    if strands[recent[k]].class == class then table.remove(recent, k); break end
  end
  table.insert(recent, 1, index)
end

-- The whole onset is absorbed before the sonority is taken, so a chord wider
-- than n leaves its own lowest notes standing rather than its predecessor's.
--contract: strands, n → a Sonority per onset: last n distinct classes struck, plus sounding
function sonority.walk(strands, n)
  local strikes, sonorities, recent, at = strikesInOrder(strands), {}, {}, 1
  while at <= #strikes do
    local ppq = strikes[at].ppq
    while at <= #strikes and strikes[at].ppq == ppq do
      promote(recent, strands, strikes[at].strand)
      at = at + 1
    end
    local current = {}
    for position, index in ipairs(recent) do
      if position <= n or sounding(strands[index], ppq) then util.add(current, index) end
    end
    util.add(sonorities, { ppq = ppq, strands = current })
  end
  return sonorities
end

----- The objective

-- The pull is counted once per strand rather than once per note, so an octave
-- doubling changes no answer: the box already charges it nothing.
--contract: strands, n, strength, choice → box over the walk + strength × strain² per strand
function sonority.cost(strands, n, strength, choice)
  local total = 0
  for _, current in ipairs(sonority.walk(strands, n)) do
    local coordSet = {}
    for _, index in ipairs(current.strands) do
      util.add(coordSet, strands[index].shortlist[choice[index]].coords)
    end
    total = total + sonority.score(coordSet)
  end
  for index, strand in ipairs(strands) do
    local strain = strand.shortlist[choice[index]].strain
    total = total + strength * strain * strain
  end
  return total
end

----- The solve

-- A strand is live from the onset it is chosen at to the last that reads it, both
-- known before enumeration (§ Solving it), and listed in strand order for keying.
--contract: strands, sonorities → per onset the strands born there, live there, and held from before
local function schedule(strands, sonorities)
  local onsetAt = {}
  for i, current in ipairs(sonorities) do onsetAt[current.ppq] = i end

  local bornAt, lastAt = {}, {}
  for index, strand in ipairs(strands) do
    local first = strand.notes[1].ppq
    for _, note in ipairs(strand.notes) do
      if note.ppq < first then first = note.ppq end
    end
    bornAt[index], lastAt[index] = onsetAt[first], onsetAt[first]
  end
  for i, current in ipairs(sonorities) do
    for _, index in ipairs(current.strands) do lastAt[index] = i end
  end

  local plan = {}
  for i = 1, #sonorities do plan[i] = { born = {}, live = {}, held = {} } end
  for index = 1, #strands do
    util.add(plan[bornAt[index]].born, index)
    for i = bornAt[index], lastAt[index] do
      util.add(plan[i].live, index)
      if i > bornAt[index] then util.add(plan[i].held, index) end
    end
  end
  return plan
end

-- Placements at an onset: the states carried in times the candidates born there,
-- so the shortlists of everything live. Counted upfront to refuse, not begin.
local budget = 200000

local function assertAffordable(strands, plan)
  for i, onset in ipairs(plan) do
    local placements = 1
    for _, index in ipairs(onset.live) do
      placements = placements * #strands[index].shortlist
    end
    assert(placements <= budget, string.format(
      'sonority.solveToPoints: onset %d needs %d placements, over the budget of %d',
      i, placements, budget))
  end
end

-- Every combination of the shortlists of the strands born at an onset, with the
-- pull each charges — the same against every state, so charged once here.
local function placementsAt(strands, born, strength)
  local placements, at = {}, {}
  for k = 1, #born do at[k] = 1 end
  while true do
    local pull = 0
    for k, index in ipairs(born) do
      local strain = strands[index].shortlist[at[k]].strain
      pull = pull + strength * strain * strain
    end
    util.add(placements, { choice = util.clone(at), pull = pull })

    local k = #born
    while k >= 1 do
      at[k] = at[k] + 1
      if at[k] <= #strands[born[k]].shortlist then break end
      at[k] = 1; k = k - 1
    end
    if k < 1 then return placements end
  end
end

-- Cost, then the strands one by one, so an exact tie breaks deterministically rather than
-- by table order (design/adaptive-tuning.md § What the solver takes).
--contract: true iff `state` is the better of the two, the lower rank winning a tie
local function outranks(state, best, count, rankOf)
  if not best then return true end
  if state.cost ~= best.cost then return state.cost < best.cost end
  for index = 1, count do
    local mine, theirs = rankOf(state, index), rankOf(best, index)
    if mine ~= theirs then return mine < theirs end
  end
  return false
end

-- Ranks a strand by the candidate index the solve chose for it.
local function byChoice(state, index)
  return state.choice[index]
end

local function keyOf(choice, list)
  local parts = {}
  for k, index in ipairs(list) do parts[k] = choice[index] end
  return util.key(table.unpack(parts))
end

-- The state carries the whole choice vector rather than a backpointer: two
-- generations are alive at a time and the budget bounds them.
--invariant: reads no cents and knows no ratios — coords/strikes/releases/classes → indices
--contract: strands, n, strength → the index per strand minimising sonority.cost, exactly
function sonority.solveToPoints(strands, n, strength)
  for index, strand in ipairs(strands) do
    assert(#strand.shortlist > 0,
      'sonority.solveToPoints: strand ' .. index .. ' has an empty shortlist')
  end
  local sonorities = sonority.walk(strands, n)
  local plan       = schedule(strands, sonorities)
  assertAffordable(strands, plan)

  local states = { [util.key()] = { cost = 0, choice = {} } }
  for i, current in ipairs(sonorities) do
    local onset = plan[i]

    local carried = {}
    for _, state in pairs(states) do
      local key = keyOf(state.choice, onset.held)
      if outranks(state, carried[key], #strands, byChoice) then carried[key] = state end
    end

    -- Every member of this sonority is now assigned: born here, or live from
    -- before. Held and born partition live, so each (state, placement) pair
    -- writes its own key, and no dominance check is needed as it is above.
    local reached = {}
    for _, placement in ipairs(placementsAt(strands, onset.born, strength)) do
      for _, state in pairs(carried) do
        local choice = util.clone(state.choice)
        for k, index in ipairs(onset.born) do choice[index] = placement.choice[k] end

        local coordSet = {}
        for k, index in ipairs(current.strands) do
          coordSet[k] = strands[index].shortlist[choice[index]].coords
        end

        local cost = state.cost + sonority.score(coordSet) + placement.pull
        reached[keyOf(choice, onset.live)] = { cost = cost, choice = choice }
      end
    end
    states = reached
  end

  local best
  for _, state in pairs(states) do
    if outranks(state, best, #strands, byChoice) then best = state end
  end
  return best.choice
end

----- The springs

-- Each member's pure position is the first's seat plus its coords' cents; a spring's delta
-- is the difference of the nearest-octave gaps to each seat (design/adaptive-springs.md § The model).
--shape: Spring = { i=<strand>, j=<strand>, delta=<cents> }; the pair is pure where d[j] - d[i] = delta
--contract: members, seat, spelling → { box=sonority.score(spelling), springs={ Spring,.. } }
--contract: springs one per pair in member order, i before j
function sonority.springs(members, seat, spelling)
  local devs = {}
  for k, coords in ipairs(spelling) do
    local pure = seat[members[1]] + tuning.cents(coords)
    devs[k] = tuning.gapTo(seat[members[k]], pure)
  end

  local springs = {}
  for a = 1, #members do
    for b = a + 1, #members do
      util.add(springs, { i = members[a], j = members[b], delta = devs[b] - devs[a] })
    end
  end
  return { box = sonority.score(spelling), springs = springs }
end

----- The placement

-- The moves facility's solve: the target read as intervals between strands rather than
-- as points. The lattice search that stood here is retired, and the springs solve lands
-- in its place (design/adaptive-springs.md § Where it sits).
--contract: strands, n, strength, notation, moves → nil, until the springs solve lands
function sonority.solveToMoves(strands, n, strength, notation, moves)
  return nil
end

return sonority
