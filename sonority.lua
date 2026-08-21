-- The objective an adaptive-tuning solve minimises, and the strands it is taken over.
-- See docs/sonority.md for the model. @noindex

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
-- bass to the sonority that follows (§ The walk).
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
-- known before enumeration (design/adaptive-tuning.md § Solving it), and listed in strand order for keying.
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
-- is the difference of the nearest-octave gaps to each seat (§ The springs).
--shape: Spring = { i=<strand>, j=<strand>, delta=<cents>, weight=<its two members' presence, multiplied> }; the pair is pure where d[j] - d[i] = delta
--contract: members, spelling per member; seat/presence per strand → a Spring per pair, i before j
--contract: springs alone: a spelling's box is sonority.score(spelling), charged where it is chosen
function sonority.springs(members, seat, presence, spelling)
  local devs = {}
  for k, coords in ipairs(spelling) do
    local pure = seat[members[1]] + tuning.cents(coords)
    devs[k] = tuning.gapTo(seat[members[k]], pure)
  end

  local springs = {}
  for a = 1, #members do
    for b = a + 1, #members do
      util.add(springs, { i = members[a], j = members[b], delta = devs[b] - devs[a],
                          weight = presence[members[a]] * presence[members[b]] })
    end
  end
  return springs
end

-- The unit both charges are measured in: what a half-window holds in 12-EDO, kept a
-- constant because a spring prices beating, which the notation's spacing does not scale.
local PURE = 50

-- The objective's two halves, each charged over a range its caller states, so what has
-- stopped moving is charged once and carried; the box, no part of either, is a constant charged where the spellings are chosen (§ The solve).

-- What a run of sonorities' springs charge: each spring against the gap its two strands
-- would sound pure at, the pair standing where the displacements put them.
--contract: spellings (a sonority.springs list per sonority) and displacement per strand
--contract: from, to → weight × stiffness × (mistuning/50)² per spring of those onsets
function sonority.springCost(spellings, displacement, stiffness, from, to)
  local total = 0
  for onset = from, to do
    for _, spring in ipairs(spellings[onset]) do
      local mistuning = (displacement[spring.j] - displacement[spring.i] - spring.delta) / PURE
      total = total + spring.weight * stiffness * mistuning * mistuning
    end
  end
  return total
end

-- What the pull charges: each strand's displacement from its rest, over the fifty the springs
-- are charged over, a notation's own spacing measuring nothing here (§ The pull in cents; § The ambient reference).
--contract: displacement per strand, rest per strand, strands: the ones to charge
--contract: → strength × strain² apiece, strain = (displacement − rest) / 50
function sonority.pullCost(displacement, rest, strength, strands)
  local total = 0
  for _, index in ipairs(strands) do
    local strain = (displacement[index] - rest[index]) / PURE
    total = total + strength * strain * strain
  end
  return total
end

----- The relaxation

-- A ten-thousandth of a cent is far under hearing and the sweeps converge geometrically,
-- so the cap is a guard and not a schedule: an iterate that reaches it is already there.
local TOLERANCE, SWEEPS = 1e-4, 1000

-- Where each spring would stand its two strands, given the other: i a delta below j, j a
-- delta above i, gathered for the strands that sweep since a held strand reads only its neighbours' ties, pre-summed since they stand still while the sweeps run.
--shape: Ties = { [strand] = { other, other, .., weights={ weight, .. }, count, delta=<the weighted tie deltas summed>, weight=<the weights summed> } }
--contract: springs per onset, the strands that sweep, the onsets to tie (all of them by default)
--contract: base: a Ties to start from, carried whole, over onsets this call does not tie again
--contract: → a Ties: the base's, and what those onsets' springs tie on top of it
function sonority.ties(springs, free, onsets, base)
  local ties, tying = {}, onsets
  for _, index in ipairs(free) do
    local carried = base and base[index]
    if carried then
      local tie = table.move(carried, 1, carried.count, 1, {})
      tie.weights = table.move(carried.weights, 1, carried.count, 1, {})
      tie.count, tie.delta, tie.weight = carried.count, carried.delta, carried.weight
      ties[index] = tie
    else
      ties[index] = { weights = {}, count = 0, delta = 0, weight = 0 }
    end
  end

  if not tying then
    tying = {}
    for onset = 1, #springs do tying[onset] = onset end
  end
  for _, onset in ipairs(tying) do
    for _, spring in ipairs(springs[onset]) do
      local low, high = ties[spring.i], ties[spring.j]
      if low then
        low.count, low.weight = low.count + 1, low.weight + spring.weight
        low.delta = low.delta - spring.weight * spring.delta
        low[low.count], low.weights[low.count] = spring.j, spring.weight
      end
      if high then
        high.count, high.weight = high.count + 1, high.weight + spring.weight
        high.delta = high.delta + spring.weight * spring.delta
        high[high.count], high.weights[high.count] = spring.i, spring.weight
      end
    end
  end
  return ties
end

-- One strand's optimum with its neighbours held: what its springs ask of it against its
-- rest, the two dials weighting them and the fifty both are charged over dividing out.
local function settle(ties, displacement, strength, stiffness, rest)
  local count, seats = ties.count, ties.delta
  for k = 1, count do seats = seats + ties.weights[k] * displacement[ties[k]] end
  if count == 0 then return rest end -- a strand no spring ties, settling at its rest

  return (stiffness * seats + strength * rest) / (stiffness * ties.weight + strength)
end

--invariant: convex in the displacements, so the sweep order and the start buy speed, not the answer
--contract: ties, strength, stiffness, start and rest (per strand), free (strands that sweep)
--contract: → displacements minimising springCost + pullCost, held strands at their start
function sonority.relax(ties, strength, stiffness, start, rest, free)
  local displacement = table.move(start, 1, #start, 1, {})

  for _ = 1, SWEEPS do
    local worst = 0
    for _, index in ipairs(free) do
      local settled = settle(ties[index], displacement, strength, stiffness, rest[index])
      local moved   = math.abs(settled - displacement[index])
      if moved > worst then worst = moved end
      displacement[index] = settled
    end
    if worst < TOLERANCE then break end
  end
  return displacement
end

----- The candidates

-- A join's coords: the host's plus the move's, a cancelled prime dropped so two chains
-- arriving at one spelling key alike (§ The candidates).
local function joinCoords(coords, move)
  local sum = {}
  for prime, exponent in pairs(coords) do sum[prime] = exponent end
  for prime, exponent in pairs(move.coords) do
    local total = (sum[prime] or 0) + exponent
    sum[prime] = total ~= 0 and total or nil
  end
  return sum
end

-- Coords are differences, so reading a member in another frame is one vector shift: what
-- stood at `from` stands at `to`, a cancelled prime dropped as joinCoords drops it.
local function rebase(coords, from, to)
  local shifted = {}
  for prime, exponent in pairs(coords) do shifted[prime] = exponent end
  for prime, exponent in pairs(from)   do shifted[prime] = (shifted[prime] or 0) - exponent end
  for prime, exponent in pairs(to)     do shifted[prime] = (shifted[prime] or 0) + exponent end
  for prime, exponent in pairs(shifted) do
    if exponent == 0 then shifted[prime] = nil end
  end
  return shifted
end

-- Coords in one order, so two tables holding the same exponents read alike.
local function coordString(coords)
  local primes = util.keys(coords)
  table.sort(primes)
  local exponents = {}
  for k, prime in ipairs(primes) do exponents[k] = prime .. ':' .. coords[prime] end
  return table.concat(exponents, ',')
end

-- What a state has made of a member: the coords it was spelled at, and the component it
-- joined into, so a member in a component of its own reads apart from the same coords tied in.
local function tokenOf(placed)
  return placed.component .. '@' .. coordString(placed.coords)
end

-- What a join costs where it lands: what it widens its component's box by over the box that
-- component came in carrying, and a spring against each member already there (§ The candidates).
local function joinCost(state, component, placed, stiffness, carried)
  local coordSet = {}
  for _, slot in ipairs(component) do util.add(coordSet, state.at[slot].coords) end
  util.add(coordSet, placed.coords)

  local cost = sonority.score(coordSet) - carried
  for _, slot in ipairs(component) do
    local mistuning = (placed.deviation - state.at[slot].deviation) / PURE
    cost = cost + placed.presence * state.at[slot].presence * stiffness * mistuning * mistuning
  end
  return cost
end

-- A slot the state has left waiting, keyed apart from the '' of one it has yet to decide.
local DEFERRED = '?'

-- Scored and keyed before it is built, so a candidate repeating a spelling costs its coords
-- and its key alone, and a round builds only the states its cut goes on to keep.
--shape: Candidate = { from=State, slot, placed=Placed|nil, parts, key, score, waits }
--shape: State = { at={ [slot]=Placed }, components={ {slot,..},.. }, parts, key, waits, score }
--shape: Placed = { coords=Coords, cents=<the pure position>, deviation=<from the seat>, presence, component }
--invariant: no two members take one spelling, so a sonority states as many pitches as members
local function propose(reached, seen, state, slot, placed, stiffness, carried)
  local token = placed and tokenOf(placed) or DEFERRED
  local parts = util.clone(state.parts)
  parts[slot] = token
  if placed then
    for other = 1, #parts do
      if other ~= slot and parts[other] == token then return end
    end
  end

  -- The parts are strings already, so the key is joined as util.keyFrom would join it,
  -- without the tostring pass it makes: this is the round's hottest line.
  local key = table.concat(parts, '\0')
  if seen[key] then return end
  seen[key] = true

  local score = state.score
  if placed then
    score = score + joinCost(state, state.components[placed.component] or {}, placed,
                             stiffness, carried)
  end
  util.add(reached, { from = state, slot = slot, placed = placed, parts = parts, key = key,
                      score = score, waits = state.waits + (placed and 0 or 1) })
end

-- The state a candidate names, built once the cut has kept it.
local function materialise(candidate)
  local state, placed = candidate.from, candidate.placed
  local child = { at = util.clone(state.at), components = {}, parts = candidate.parts,
                  key = candidate.key, waits = candidate.waits, score = candidate.score }
  for index, slots in ipairs(state.components) do child.components[index] = util.clone(slots) end
  if placed then
    child.at[candidate.slot] = placed
    child.components[placed.component] = child.components[placed.component] or {}
    util.add(child.components[placed.component], candidate.slot)
  end
  return child
end

-- Score, then the spelling itself, so an exact tie breaks on the coords rather than on
-- table order, as sonority.solveToPoints breaks its own.
local function byScore(a, b)
  if a.score ~= b.score then return a.score < b.score end
  return a.key < b.key
end

-- One round per member decides one slot: a move to a member already placed, or left waiting.
-- Every road decides the same slots, so a differing order's duplicates collapse where they land.
--invariant: a round decides one slot, so the states it cuts between have placed equally many
--invariant: the first member to place anchors and those before it wait, so one anchor spells each
--invariant: every state ties every member it places; an untied one states nothing, charges none
local function beamOver(seat, free, presence, moves, width, stiffness)
  local start = { at = {}, components = {}, parts = {}, waits = 0, score = 0 }
  for slot = 1, #seat do start.parts[slot] = '' end
  start.key = table.concat(start.parts, '\0')

  local beam = { start }
  for _ = 1, #seat do
    local reached, seen = {}, {}
    for _, state in ipairs(beam) do
      local anchored = next(state.at) ~= nil

      -- The box a component stands at is the state's own, so every move joining it this
      -- round is priced against one reading of it rather than against a reading apiece.
      local carried = {}
      for index, slots in ipairs(state.components) do
        local coordSet = {}
        for _, held in ipairs(slots) do util.add(coordSet, state.at[held].coords) end
        carried[index] = sonority.score(coordSet)
      end

      for slot = 1, #seat do
        if state.parts[slot] == '' then
          if free[slot] then
            propose(reached, seen, state, slot, nil, stiffness)
          end
          if anchored then
            for host = 1, #seat do
              local from = state.at[host]
              if from then
                for _, move in ipairs(moves) do
                  if move.height > 0 then
                    local cents = from.cents + move.cents
                    propose(reached, seen, state, slot,
                            { coords = joinCoords(from.coords, move), cents = cents,
                              deviation = tuning.gapTo(seat[slot], cents),
                              presence = presence[slot], component = from.component },
                            stiffness, carried[from.component])
                  end
                end
              end
            end
          else
            propose(reached, seen, state, slot,
                    { coords = {}, cents = seat[slot], deviation = 0,
                      presence = presence[slot], component = 1 },
                    stiffness, 0)
            break
          end
        end
      end
    end

    table.sort(reached, byScore)
    beam = {}
    local kept = {}
    for _, candidate in ipairs(reached) do
      kept[candidate.waits] = (kept[candidate.waits] or 0) + 1
      if kept[candidate.waits] <= width then util.add(beam, materialise(candidate)) end
    end
  end
  return beam
end

-- What coords and seats state about a set of members: a spring per pair of a component,
-- tied in member order as sonority.springs ties them, and the box a component carries.
--contract: members, seat/presence per strand, coords/component per placed member → springs, box
--contract: a member the map lacks is one still waiting, which states nothing and is passed over
local function chargeOf(members, seat, presence, placed)
  local groups, components = {}, {}
  for _, member in ipairs(members) do
    local at = placed[member]
    if at then
      if not groups[at.component] then
        groups[at.component] = {}
        util.add(components, at.component)
      end
      util.add(groups[at.component], member)
    end
  end

  local springs, box = {}, 0
  for _, component in ipairs(components) do
    local group, relative, deviation = groups[component], {}, {}
    local first  = group[1]
    local origin = placed[first].coords
    relative[1], deviation[1] = {}, 0
    for k = 2, #group do
      relative[k]  = rebase(placed[group[k]].coords, origin, {})
      deviation[k] = tuning.gapTo(seat[group[k]], seat[first] + tuning.cents(relative[k]))
    end

    for a = 1, #group do
      for b = a + 1, #group do
        util.add(springs, { i = group[a], j = group[b], delta = deviation[b] - deviation[a],
                            weight = presence[group[a]] * presence[group[b]] })
      end
    end
    if #group > 1 then box = box + sonority.score(relative) end
  end
  return springs, box
end

-- The state read back as the sonority's own: its members' coords under the strands they
-- name, whom it left waiting, and what those state charged as any set of placed members is.
local function spellingOf(state, members, seat, presence)
  local placed, waiting = {}, {}
  for slot, member in ipairs(members) do
    if state.at[slot] then
      placed[member] = { coords    = state.at[slot].coords,
                         component = state.at[slot].component }
    else
      util.add(waiting, member)
    end
  end

  local springs, box = chargeOf(members, seat, presence, placed)
  return { box = box, springs = springs, waiting = waiting, placed = placed }
end

-- A waiting member states no interval, so waiting is a choice the beam makes per member; a
-- deferral is no rival to a spelling, so the cut runs within a waiting count (§ The candidates).
--shape: Spelling = { box=<what its components carry>, springs={Spring,..}, waiting={member,..}, placed={ [strand]={ coords=Coords, component } } }
--contract: members; seat/presence/mayWait per strand; moves/width/stiffness → Spellings, best first
--contract: a join is one move; a spelling states intervals, and stands at any offset from the seats
--contract: the width is a width per waiting count; math.huge enumerates the spellings whole
--contract: a target stating no move spells nothing: the list is empty
function sonority.spellings(members, seat, presence, mayWait, moves, width, stiffness)
  local seats, free, presences = {}, {}, {}
  for slot, member in ipairs(members) do
    seats[slot]     = seat[member]
    free[slot]      = mayWait[member] or false
    presences[slot] = presence[member]
  end

  local spellings = {}
  for k, state in ipairs(beamOver(seats, free, presences, moves, width, stiffness)) do
    spellings[k] = spellingOf(state, members, seat, presence)
  end
  return spellings
end

----- The terms

-- One seat serves a strand in every register, so notes[1] speaks for all of them; the
-- seat keeps the register it was written in, which tuning.gapTo quotients out again.
--contract: strands, notation → the cents of each strand's written step
function sonority.seats(strands, notation)
  local seat = {}
  for index, strand in ipairs(strands) do
    seat[index] = tuning.seatWindow(notation, strand.notes[1])
  end
  return seat
end

-- What a member held by recency counts for beside one that sounds: a spring prices beating,
-- and beating wants two sounding pitches (§ Presence).
local RECENT = 0.5

-- A member is free to wait while an onset it sounds through is still to come; at that onset
-- it places or the state fails (§ The candidates).
--shape: Onset = { ppq, members={strand,..}, sounding={strand,..}, presence={[strand]=<1 or RECENT>}, mayWait={[strand]=true,..} }
--contract: strands, sonorities → an Onset per sonority, its members the walk's own
--contract: a member the sonority holds by recency has stopped: it neither sounds nor waits
function sonority.onsets(strands, sonorities)
  local onsets = {}
  for i, current in ipairs(sonorities) do
    local live, presence = {}, {}
    for _, index in ipairs(current.strands) do
      local sounds = sounding(strands[index], current.ppq)
      if sounds then util.add(live, index) end
      presence[index] = sounds and 1 or RECENT
    end
    onsets[i] = { ppq = current.ppq, members = current.strands, sounding = live,
                  presence = presence, mayWait = {} }
  end

  local later = {}
  for i = #onsets, 1, -1 do
    for _, index in ipairs(onsets[i].members) do
      if later[index] then onsets[i].mayWait[index] = true end
    end
    for _, index in ipairs(onsets[i].sounding) do later[index] = true end
  end
  return onsets
end

----- The search

-- What the future reads of a past is its cents, and half a cent is under what tells two
-- placements apart, so answers agreeing that closely on the strands ahead are one answer.
local AUDIBLE = 0.5

-- The strands a later onset names and the walk has already moved, in strand order: all a
-- continuation can read, since what nothing ahead names is settled and what nothing behind has sounded stands at zero alike (§ The solve).
local function visibleAhead(onsets)
  local named, later = {}, {}
  for i = #onsets, 1, -1 do
    later[i] = util.keys(named)
    for _, index in ipairs(onsets[i].members) do named[index] = true end
  end

  local moved, ahead = {}, {}
  for i = 1, #onsets do
    for _, index in ipairs(onsets[i].sounding) do moved[index] = true end
    ahead[i] = {}
    for _, index in ipairs(later[i]) do
      if moved[index] then util.add(ahead[i], index) end
    end
    table.sort(ahead[i])
  end
  return ahead
end

-- The same run read the other way: an onset's strands split into those a later onset sounds
-- too, which the relaxation can still move, and those it sounded last, which have stopped.
--contract: onsets → per onset the strands it leaves moving and the strands it closes
local function soundingRuns(onsets)
  local later, moving, stopped = {}, {}, {}
  for i = #onsets, 1, -1 do
    moving[i], stopped[i] = {}, {}
    for _, index in ipairs(onsets[i].sounding) do
      util.add(later[index] and moving[i] or stopped[i], index)
    end
    for _, index in ipairs(onsets[i].sounding) do later[index] = true end
  end
  return moving, stopped
end

-- A strand sounds over one run of onsets, so once the walk is past every strand an onset
-- named, nothing it charges can move again: the onsets before the cursor are closed.
--invariant: the cursor only advances, so a closed onset stays closed for the rest of the walk
--contract: onsets → per onset the earliest onset a strand sounding there is named at
local function openFrom(onsets)
  local born, from = {}, {}
  for i, onset in ipairs(onsets) do
    for _, index in ipairs(onset.members) do
      if not born[index] then born[index] = i end
    end
    local first = i
    for _, index in ipairs(onset.sounding) do
      if born[index] < first then first = born[index] end
    end
    from[i] = first
  end
  return from
end

-- The difference of two coords read straight to its string: what coordString would read
-- of the rebase, fused so a key costs no intermediate table.
local function diffString(coords, from)
  if coords == from then return '' end
  local diff = {}
  for prime, exponent in pairs(coords) do diff[prime] = exponent end
  for prime, exponent in pairs(from)   do diff[prime] = (diff[prime] or 0) - exponent end

  local primes = {}
  for prime, exponent in pairs(diff) do
    if exponent ~= 0 then util.add(primes, prime) end
  end
  table.sort(primes)
  local parts = {}
  for k, prime in ipairs(primes) do parts[k] = prime .. ':' .. diff[prime] end
  return table.concat(parts, ',')
end

-- What a sonority has been spelled as, however the spelling was reached: each component
-- read from its earliest member, as chargeOf reads it, and the members still waiting.
--invariant: two placements under one key charge alike, so a wait reaching one is no second road
local function placementKey(members, placed, waiting)
  local groups, components, parts = {}, {}, {}
  for _, member in ipairs(members) do
    local at = placed[member]
    if at then
      if not groups[at.component] then
        groups[at.component] = {}
        util.add(components, at.component)
      end
      util.add(groups[at.component], member)
    end
  end

  for _, component in ipairs(components) do
    local group  = groups[component]
    local origin = placed[group[1]].coords
    for _, member in ipairs(group) do
      util.add(parts, member)
      util.add(parts, diffString(placed[member].coords, origin))
    end
    util.add(parts, '/')
  end

  local held = util.keys(waiting)
  table.sort(held)
  for _, member in ipairs(held) do util.add(parts, member) end
  return util.keyFrom(parts)
end

-- What each onset's beam returned, read as placements: the spellings a wait may not come
-- back with, taken from what the beam kept rather than what its moves could have reached.
local function offeredBy(onsets, spellings)
  local offered = {}
  for i, list in ipairs(spellings) do
    offered[i] = {}
    for _, spelling in ipairs(list) do
      local waiting = {}
      for _, member in ipairs(spelling.waiting) do waiting[member] = true end
      offered[i][placementKey(onsets[i].members, spelling.placed, waiting)] = true
    end
  end
  return offered
end

-- An answer under the whole of what a continuation can tell it by: its cents at the strands
-- ahead in half-cents, and the deferrals it has yet to pay.
--invariant: one strand list serves every answer of an onset, so its cents key by position
local function answerKey(displacement, ahead, onsets, held)
  local parts = {}
  for k, index in ipairs(ahead) do
    parts[k] = util.round(displacement[index] / AUDIBLE)
  end

  for _, entry in ipairs(held) do
    util.add(parts, entry.onset)
    for _, member in ipairs(onsets[entry.onset].members) do
      local at = entry.placed[member]
      util.add(parts, at and tokenOf(at) or (entry.waiting[member] and '?' or ''))
    end
  end
  return util.keyFrom(parts)
end

-- What a spelling makes of a sonority still waiting: a waiter it places takes coords in the
-- held sonority's frame through a member the two share, and nothing where they share none.
--invariant: a waiter reaching two components merges them, every member shifted into the one frame
--invariant: a waiter tied to no member states no interval there, so its completion fails
local function complete(entry, members, spelling)
  local lands = false
  for _, member in ipairs(members) do
    if entry.waiting[member] and spelling.placed[member] then lands = true break end
  end
  if not lands then return entry.placed, entry.waiting, false end

  local placed, waiting = util.clone(entry.placed), util.clone(entry.waiting)

  for _, member in ipairs(members) do
    local landing = waiting[member] and spelling.placed[member]
    if landing then
      local hosts = {}
      for _, other in ipairs(members) do
        local host = spelling.placed[other]
        if placed[other] and host and host.component == landing.component then
          util.add(hosts, other)
        end
      end
      if #hosts == 0 then return nil end

      waiting[member] = nil

      local component = placed[hosts[1]].component
      local coords    = rebase(landing.coords, spelling.placed[hosts[1]].coords,
                               placed[hosts[1]].coords)
      placed[member] = { coords = coords, component = component }

      for k = 2, #hosts do
        local merging = placed[hosts[k]].component
        if merging ~= component then
          local through = rebase(landing.coords, spelling.placed[hosts[k]].coords,
                                 placed[hosts[k]].coords)
          for other, at in pairs(placed) do
            if at.component == merging then
              placed[other] = { coords = rebase(at.coords, through, coords),
                                component = component }
            end
          end
        end
      end
    end
  end
  return placed, waiting, true
end

-- The entry a spelling that defers opens: which onset owes it, what it placed, whom it
-- left, and what it has been charged so far.
local function heldBy(spelling, at)
  local waiting = {}
  for _, member in ipairs(spelling.waiting) do waiting[member] = true end
  return { onset = at, placed = spelling.placed, waiting = waiting, box = spelling.box }
end

-- The onsets behind the cursor an answer has settled: the open ones, less any a deferral
-- still rewrites, so what every spelling of the next onset reads alike is tied once.
local function settledOnsets(answer, from, at)
  local rewritten, settled = {}, {}
  for _, entry in ipairs(answer.held) do rewritten[entry.onset] = true end
  for onset = from, at - 1 do
    if not rewritten[onset] then util.add(settled, onset) end
  end
  return settled
end

-- Where a pool's cut now sits: the cost of its cap-th best distinct key, held in a
-- bounded sorted list, a listed key replaced where it improved (§ The solve).
--invariant: a key's cost in reached only improves, so a stale bar is only ever too high
local function cutBar(cap)
  local keys, costs = {}, {}
  local pool = { bar = math.huge }
  function pool.saw(key, cost)
    for k = 1, #keys do
      if keys[k] == key then
        if cost >= costs[k] then return end
        table.remove(keys, k)
        table.remove(costs, k)
        break
      end
    end

    local at = #costs + 1
    for k = 1, #costs do
      if cost < costs[k] then at = k break end
    end
    if at > cap then return end
    table.insert(keys, at, key)
    table.insert(costs, at, cost)
    keys[cap + 1], costs[cap + 1] = nil, nil
    if #costs == cap then pool.bar = costs[cap] end
  end
  return pool
end

-- One answer extended by one spelling: the springs and box it has paid, each sonority it
-- still holds charged again for what this spelling places, the onset's own strands relaxed.
--contract: carried: the Ties over what the answer has settled, which this spelling's start from
--contract: nil where a wait comes back with a placement its own sonority offered (§ The candidates)
--contract: nil where a wait lands tied to no member of the sonority that deferred it
local function extend(answer, spelling, onsets, at, seat, strength, stiffness, rest,
                      offered, carried, from, since, moving, stopped, bars)
  local springs, held = table.move(answer.springs, 1, at - 1, 1, {}), {}
  local box, written = answer.box + spelling.box, {}
  springs[at] = spelling.springs

  for _, entry in ipairs(answer.held) do
    local onset   = entry.onset
    local members = onsets[onset].members
    local placed, waiting, landed = complete(entry, members, spelling)
    if not placed then return nil end
    if landed then
      if offered[onset][placementKey(members, placed, waiting)] then return nil end

      local charged, widened = chargeOf(members, seat, onsets[onset].presence, placed)

      springs[onset] = charged
      box = box - entry.box + widened
      if next(waiting) then
        util.add(held, { onset = onset, placed = placed, waiting = waiting, box = widened })
      end
    else
      util.add(held, entry)
    end
    if onset >= from then util.add(written, onset) end
  end
  if #spelling.waiting > 0 then util.add(held, heldBy(spelling, at)) end

  -- box + closed is a floor under the cost, sums of squares both; a floor over the
  -- pool's bar can't survive the cut, so it's refused before ties or relaxation (§ The solve).
  if box + answer.closed > bars[held[1] and 'owing' or 'paid'].bar then return nil end

  -- Only the onsets this spelling wrote are tied here — its own, and the deferrals it
  -- completed; the rest the answer tied before its spellings were tried.
  util.add(written, at)
  local sweeping = onsets[at].sounding
  local displacement = sonority.relax(sonority.ties(springs, sweeping, written, carried),
                                      strength, stiffness, answer.displacement, rest, sweeping)

  -- What closed since the last extension is charged once, at displacements that will not move
  -- again and carried: the onsets the cursor has passed, and this onset's strands sounded for the last time (§ The solve).
  local closed = answer.closed
               + sonority.springCost(springs, displacement, stiffness, since, from - 1)
               + sonority.pullCost(displacement, rest, strength, stopped)
  return { choice = table.move(answer.choice, 1, at - 1, 1, {}), springs = springs,
           box = box, held = held, displacement = displacement, closed = closed,
           cost = box + closed
                + sonority.springCost(springs, displacement, stiffness, from, at)
                + sonority.pullCost(displacement, rest, strength, moving) }
end

-- The cost is taken over every spring accumulated so far rather than the onset's own, so
-- a spelling is priced against the past it is chosen behind (§ The solve).
--invariant: what has closed is carried, which is what retaking it a cursor later would charge
--shape: Answer = { choice={ spelling per onset }, springs={ Spring list per onset }, box, displacement, cost, closed=<what the shut onsets charge>, held={ Held,.. } }
--shape: Held = { onset, placed={ [strand]={ coords=Coords, component } }, waiting={ [strand]=true }, box=<charged so far> }
--invariant: an answer's debts stand in onset order, as the walk opens them and closes them in it
--contract: onsets, a spelling list per onset, seat per strand, strength, stiffness, cap
--contract: → the cheapest Answer, every answer carried extended by every spelling of the onset
--contract: the strands the onset sounds relax; the rest of an answer stands at the cents it carries
--contract: a sonority holding a waiter is charged in its own onset's slot, as its members place
--contract: answers agreeing to half a cent ahead and owing the same merge; the set is cut to cap
--contract: the cut runs over two pools, the answers that owe and the answers that have paid
--contract: nil where an onset has no spelling — which is a target stating no move
function sonority.search(onsets, spellings, seat, strength, stiffness, cap)
  local ahead, start, rest, offered = visibleAhead(onsets), {}, {}, offeredBy(onsets, spellings)
  local from = openFrom(onsets)
  local moving, stopped = soundingRuns(onsets)
  for index = 1, #seat do start[index], rest[index] = 0, 0 end
  local answers = { { choice = {}, springs = {}, box = 0, displacement = start, cost = 0,
                      closed = 0, held = {} } }

  for i = 1, #onsets do
    local reached = {}
    local bars = { owing = cutBar(cap), paid = cutBar(cap) }
    for _, answer in ipairs(answers) do
      local carried = sonority.ties(answer.springs, onsets[i].sounding,
                                    settledOnsets(answer, from[i], i))
      for choice, spelling in ipairs(spellings[i]) do
        local state = extend(answer, spelling, onsets, i, seat, strength, stiffness, rest,
                             offered, carried, from[i], i > 1 and from[i - 1] or 1,
                             moving[i], stopped[i], bars)
        if state then
          state.choice[i] = choice

          local key = answerKey(state.displacement, ahead[i], onsets, state.held)
          if outranks(state, reached[key], i, byChoice) then
            reached[key] = state
            bars[state.held[1] and 'owing' or 'paid'].saw(key, state.cost)
          end
        end
      end
    end

    -- A deferral moves charge out of the running score rather than paying it, so a road that
    -- owes is cut among the roads that owe, and never against one that has paid (§ The solve).
    local paid, owing = {}, {}
    for _, state in pairs(reached) do util.add(state.held[1] and owing or paid, state) end

    answers = {}
    for _, pool in ipairs{ paid, owing } do
      table.sort(pool, function(a, b) return outranks(a, b, i, byChoice) end)
      for k = 1, math.min(cap, #pool) do util.add(answers, pool[k]) end
    end
    table.sort(answers, function(a, b) return outranks(a, b, i, byChoice) end)
  end
  return answers[1]
end

----- The placement

-- Beam width and walk breadth (§ The solve): the width is doing work,
-- the cap one over the lowest that answers alike at this width on every passage measured.
local WIDTH, CAP = 24, 4

-- The moves facility's solve: intervals rather than points, spelled by the beam under a
-- frozen past, settled by joint relaxation (§ The solve).
--contract: strands, n, strength, notation, moves, stiffness → the cents each strand settles at
--contract: nil where an onset has no spelling — which is a target stating no move
function sonority.solveToMoves(strands, n, strength, notation, moves, stiffness)
  local seat = sonority.seats(strands, notation)
  local onsets, spellings = sonority.onsets(strands, sonority.walk(strands, n)), {}
  for i, onset in ipairs(onsets) do
    spellings[i] = sonority.spellings(onset.members, seat, onset.presence, onset.mayWait,
                                      moves, WIDTH, stiffness)
  end

  local answer = sonority.search(onsets, spellings, seat, strength, stiffness, CAP)
  if not answer then return nil end

  local free, rest = {}, {}
  for index = 1, #strands do free[index], rest[index] = index, 0 end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), strength,
                                      stiffness, answer.displacement, rest, free)

  local cents = {}
  for index = 1, #strands do cents[index] = seat[index] + displacement[index] end
  return cents
end

return sonority
