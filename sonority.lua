-- The objective an adaptive-tuning solve minimises, and the strands it is taken over.
-- See design/adaptive-tuning.md § What "in tune" means, and design/adaptive-ji.md § A placement is a tree. @noindex

--invariant: pure module: no state; ratios/cents are tuning.lua's, the placement carries them
--shape: Coords = {[oddPrime]=exponent}; prime 2 is absent, so the score reads harmony not spacing
--shape: Strand = { notes={ {ppq,pitch,endppq,..},.. }, class=<step-class>, shortlist={ Candidate,.. } }; the walk reads the strikes, the releases and the class
--shape: Sonority = { ppq, strands={ strandIndex,.. } }; most recently struck first, the last n struck and whatever else still sounds
--shape: Candidate = { coords=Coords, strain=<distance from the written step, in half-windows> }
--shape: Tuning = { cents, coords=Coords, strain, key=<the coords' identity> }; what a placement seats a strand at
--shape: Placement = { cost, tunings={ [strandIndex]=Tuning,.. } }; one tuning per strand, at a stated offset

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
      'sonority.solve: onset %d needs %d placements, over the budget of %d',
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
function sonority.solve(strands, n, strength)
  for index, strand in ipairs(strands) do
    assert(#strand.shortlist > 0,
      'sonority.solve: strand ' .. index .. ' has an empty shortlist')
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

----- The placement

-- An entry ranks on the coords each strand reached, and a strand it has yet to place
-- ranks before any it has, so two entries compare on the strands they have in common.
local function byTuningKey(entry, index)
  local chosen = entry.tunings[index]
  return chosen and chosen.key or ''
end

-- The anchors themselves, in strand order, so that the candidates come back in one
-- order however the placement was grown.
local function anchorsOf(tunings, list)
  local anchors = {}
  for _, index in ipairs(list) do
    local chosen = tunings[index]
    if chosen then util.add(anchors, { cents = chosen.cents, coords = chosen.coords }) end
  end
  return anchors
end

-- Two placements agreeing on the tuning of every strand listed are one, whichever order
-- or history reached them; position names the strand, so an unplaced one keys as false.
local function placementKey(tunings, list)
  local parts = {}
  for k, index in ipairs(list) do
    parts[k] = tunings[index] and tunings[index].key or false
  end
  return util.key(table.unpack(parts))
end

-- An onset striking a sonority's worth of classes evicts everything not still sounding,
-- so the sonority before it stays attachable there, and only there (design/adaptive-ji.md § A placement is a tree).
--contract: sonorities, plan → per onset the attachable strands, and those the carry must tell apart
local function attachable(sonorities, plan)
  local memory = {}
  for i, onset in ipairs(plan) do
    local anchors, carry = util.clone(onset.live), util.clone(onset.held)
    if i > 1 and #onset.held == 0 then
      local live = {}
      for _, index in ipairs(onset.live) do live[index] = true end
      for _, index in ipairs(sonorities[i - 1].strands) do
        if not live[index] then util.add(anchors, index); util.add(carry, index) end
      end
      table.sort(anchors)
      table.sort(carry)
    end
    memory[i] = { anchors = anchors, carry = carry }
  end
  return memory
end

-- Counted as the entries are reached rather than read off the walk: a strand's candidates
-- depend on where the others went, so there is no product of shortlists to take in advance.
local function spend(search)
  search.reached = search.reached + 1
  assert(search.reached <= budget, string.format(
    'sonority.place: onset %d reaches over the budget of %d entries', search.at, budget))
end

-- Grown outward from the root, taking any unplaced strand from any strand already placed:
-- an order fixed in advance would lose the trees that reach a strand through a later one (design/adaptive-ji.md § What it costs to solve).
local function growFrom(search, entry, onset, memory)
  local strands, frontier, first = search.strands, { entry }, 1

  -- The passage's one root: the strand seated as written, at the only onset with
  -- nothing to attach to (design/adaptive-ji.md § Where a placement sits).
  if #memory.carry == 0 then
    local index = onset.born[1]
    local root  = tuning.origin(search.notation, strands[index].notes[1], search.offset)
    if not root then return {} end
    local tunings  = util.clone(entry.tunings)
    tunings[index] = root
    frontier = { { cost    = entry.cost + search.strength * root.strain * root.strain,
                   tunings = tunings } }
    first = 2
  end

  for _ = first, #onset.born do
    local grown = {}
    for _, partial in ipairs(frontier) do
      local anchors = anchorsOf(partial.tunings, memory.anchors)
      for _, index in ipairs(onset.born) do
        if not partial.tunings[index] then
          -- One window serves a strand in every register, so notes[1] speaks for all.
          local reached = tuning.reach(search.notation, search.moves, anchors,
                                       strands[index].notes[1], search.offset)
          for _, candidate in ipairs(reached) do
            local tunings  = util.clone(partial.tunings)
            tunings[index] = candidate
            local grew = { cost    = partial.cost
                                   + search.strength * candidate.strain * candidate.strain,
                           tunings = tunings }
            local key  = placementKey(tunings, memory.anchors)
            spend(search)
            if outranks(grew, grown[key], #strands, byTuningKey) then grown[key] = grew end
          end
        end
      end
    end
    frontier = {}
    for _, grew in pairs(grown) do util.add(frontier, grew) end
  end
  return frontier
end

-- The candidate model of design/adaptive-ji.md: there is no shortlist to index, so
-- the search carries the move set and reads the tunings off tuning.lua as it goes.
--contract: strands, n, strength, notation, moves, offset → the cheapest Placement, or nil unplaced
--contract: the strand born first is the root, seated as written; each other moves from one placed
--contract: cost is sonority.cost's own: the box over the walk, plus the pull each strand spends
--contract: raises where an onset reaches more entries than the budget allows
function sonority.place(strands, n, strength, notation, moves, offset)
  local sonorities = sonority.walk(strands, n)
  local plan       = schedule(strands, sonorities)
  local memory     = attachable(sonorities, plan)
  local search     = { strands = strands, notation = notation, moves = moves,
                       offset  = offset,  strength = strength }

  local entries = { [util.key()] = { cost = 0, tunings = {} } }
  for i, current in ipairs(sonorities) do
    search.at, search.reached = i, 0

    -- Two placements agreeing on everything still attachable are one from here on,
    -- and what the onset evicted has no future left to alter.
    local carried = {}
    for _, entry in pairs(entries) do
      local key = placementKey(entry.tunings, memory[i].carry)
      if outranks(entry, carried[key], #strands, byTuningKey) then carried[key] = entry end
    end

    local reached = {}
    for _, entry in pairs(carried) do
      for _, placement in ipairs(growFrom(search, entry, plan[i], memory[i])) do
        local coordSet = {}
        for k, index in ipairs(current.strands) do
          coordSet[k] = placement.tunings[index].coords
        end
        placement.cost = placement.cost + sonority.score(coordSet)

        local key = placementKey(placement.tunings, plan[i].live)
        if outranks(placement, reached[key], #strands, byTuningKey) then
          reached[key] = placement
        end
      end
    end
    if not next(reached) then return nil end
    entries = reached
  end

  local best
  for _, entry in pairs(entries) do
    if outranks(entry, best, #strands, byTuningKey) then best = entry end
  end
  return best
end

return sonority
