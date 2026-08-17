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
--contract: members, spelling per member; seat per strand → a Spring per pair, i before j
--contract: springs alone: a spelling's box is sonority.score(spelling), charged where it is chosen
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
  return springs
end

-- The unit the stiffness is measured in: what a half-window holds in 12-EDO, kept a
-- constant because a spring prices beating, which the notation's spacing does not scale.
local PURE = 50

-- The box is no part of this: a constant once the spellings are chosen, so it is charged
-- where they are chosen rather than where the displacements are priced.
--shape: Window = { below=<cents to the step below>, above=<cents to the step above> }
--contract: spellings (a sonority.springs list per sonority), displacement and window per strand
--contract: → stiffness × (mistuning/50)² per spring + strength × strain² per half-window
function sonority.springCost(spellings, displacement, window, strength, stiffness)
  local total = 0
  for _, springs in ipairs(spellings) do
    for _, spring in ipairs(springs) do
      local mistuning = (displacement[spring.j] - displacement[spring.i] - spring.delta) / PURE
      total = total + stiffness * mistuning * mistuning
    end
  end

  for index, cents in ipairs(displacement) do
    local half   = cents < 0 and window[index].below or window[index].above
    local strain = cents / half
    total = total + strength * strain * strain
  end
  return total
end

----- The relaxation

-- A ten-thousandth of a cent is far under hearing and the sweeps converge geometrically,
-- so the cap is a guard and not a schedule: an iterate that reaches it is already there.
local TOLERANCE, SWEEPS = 1e-4, 1000

-- Where each spring would stand its two strands, given the other: i a delta below j, j a
-- delta above i. Gathered once for the strands that sweep, since a held strand never reads its own ties: it stands as a constant in its neighbours'.
local function tiesOf(spellings, free)
  local ties = {}
  for _, index in ipairs(free) do ties[index] = {} end
  for _, springs in ipairs(spellings) do
    for _, spring in ipairs(springs) do
      if ties[spring.i] then util.add(ties[spring.i], { other = spring.j, delta = -spring.delta }) end
      if ties[spring.j] then util.add(ties[spring.j], { other = spring.i, delta =  spring.delta }) end
    end
  end
  return ties
end

-- One strand's optimum with the rest held: its springs' seats averaged against the pull,
-- charged over the half-window the seats point it toward (design/adaptive-springs.md § The model).
local function settle(ties, displacement, window, strength, stiffness)
  local seats = 0
  for _, tie in ipairs(ties) do seats = seats + displacement[tie.other] + tie.delta end
  if seats == 0 then return 0 end

  local half  = seats > 0 and window.above or window.below
  local stiff = stiffness / (PURE * PURE)
  return util.clamp(stiff * seats / (stiff * #ties + strength / (half * half)),
                    -window.below, window.above)
end

--invariant: convex in the displacements, so the sweep order and the start buy speed, not the answer
--contract: spellings, window, strength, stiffness, start (per strand), free (strands that sweep)
--contract: → displacements minimising sonority.springCost, the held strands standing at their start
--contract: each swept displacement inside its own strand's window
function sonority.relax(spellings, window, strength, stiffness, start, free)
  local ties, displacement = tiesOf(spellings, free), {}
  for index = 1, #window do displacement[index] = start[index] end

  for _ = 1, SWEEPS do
    local worst = 0
    for _, index in ipairs(free) do
      local settled = settle(ties[index], displacement, window[index], strength, stiffness)
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
-- arriving at one spelling key alike (design/adaptive-springs.md § The candidates).
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

-- The neighbouring step and no further: past two half-windows some other member of the
-- sonority is the nearer host for the pitch, so the join is no longer this one's.
local function inReach(deviation, window)
  if deviation < 0 then return -deviation <= 2 * window.below end
  return deviation <= 2 * window.above
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

-- What a join costs where it lands: the box its component widens by, and a spring against
-- each member already there, both priced before any displacement moves (§ The candidates).
local function joinCost(state, component, placed, stiffness)
  local coordSet = {}
  for _, slot in ipairs(component) do util.add(coordSet, state.at[slot].coords) end
  local before = sonority.score(coordSet)
  util.add(coordSet, placed.coords)

  local cost = sonority.score(coordSet) - before
  for _, slot in ipairs(component) do
    local mistuning = (placed.deviation - state.at[slot].deviation) / PURE
    cost = cost + stiffness * mistuning * mistuning
  end
  return cost
end

-- Keyed before it is built, so a candidate repeating a spelling costs its coords and its
-- key alone; the state it would have extended is copied only where the spelling is new.
--shape: State = { at={ [slot]=Placed }, components={ {slot,..},.. }, parts, key, score }
--shape: Placed = { coords=Coords, cents=<the pure position>, deviation=<from the seat>, component }
local function admit(reached, seen, state, slot, placed, stiffness)
  local parts = util.clone(state.parts)
  parts[slot] = tokenOf(placed)
  local key = util.key(table.unpack(parts))
  if seen[key] then return end
  seen[key] = true

  local component = state.components[placed.component] or {}
  local child = { at = util.clone(state.at), components = {}, parts = parts, key = key,
                  score = state.score + joinCost(state, component, placed, stiffness) }
  for index, slots in ipairs(state.components) do child.components[index] = util.clone(slots) end
  child.components[placed.component] = child.components[placed.component] or {}
  child.at[slot] = placed
  util.add(child.components[placed.component], slot)
  util.add(reached, child)
end

-- Score, then the spelling itself, so an exact tie breaks on the coords rather than on
-- table order, as sonority.solveToPoints breaks its own.
local function byScore(a, b)
  if a.score ~= b.score then return a.score < b.score end
  return a.key < b.key
end

-- One round per member after the anchor, each joined by one move to a member already
-- placed; the unison is no join, and a state that can place nobody dies where it stands.
--invariant: every state ties every member; an untied member states nothing, so charges nothing
local function beamOver(seat, window, moves, width, stiffness)
  local anchor = { at = {}, components = {}, parts = {}, score = 0 }
  for slot = 1, #seat do anchor.parts[slot] = '' end
  if #seat > 0 then
    local placed = { coords = {}, cents = seat[1], deviation = 0, component = 1 }
    anchor.at[1], anchor.components[1], anchor.parts[1] = placed, { 1 }, tokenOf(placed)
  end
  anchor.key = util.key(table.unpack(anchor.parts))

  local beam = { anchor }
  for _ = 2, #seat do
    local reached, seen = {}, {}
    for _, state in ipairs(beam) do
      for slot = 1, #seat do
        if not state.at[slot] then
          for host = 1, #seat do
            local from = state.at[host]
            if from then
              for _, move in ipairs(moves) do
                if move.height > 0 then
                  local cents     = from.cents + move.cents
                  local deviation = tuning.gapTo(seat[slot], cents)
                  if inReach(deviation, window[slot]) then
                    admit(reached, seen, state, slot,
                          { coords = joinCoords(from.coords, move), cents = cents,
                            deviation = deviation, component = from.component }, stiffness)
                  end
                end
              end
            end
          end
        end
      end
    end

    table.sort(reached, byScore)
    beam = {}
    for k = 1, math.min(width, #reached) do beam[k] = reached[k] end
  end
  return beam
end

-- What coords and seats state about a set of members: a spring per pair of a component,
-- tied in member order as sonority.springs ties them, and the box a component carries.
--contract: members, seat per strand, coords and component per placed member → springs, box
--contract: a member the map lacks is one still waiting, which states nothing and is passed over
local function chargeOf(members, seat, placed)
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
    for k, member in ipairs(group) do
      relative[k]  = rebase(placed[member].coords, placed[group[1]].coords, {})
      deviation[k] = tuning.gapTo(seat[member], seat[group[1]] + tuning.cents(relative[k]))
    end

    for a = 1, #group do
      for b = a + 1, #group do
        util.add(springs, { i = group[a], j = group[b], delta = deviation[b] - deviation[a] })
      end
    end
    if #group > 1 then box = box + sonority.score(relative) end
  end
  return springs, box
end

-- The state read back as the sonority's own: its members' coords under the strands they
-- name, and what those state charged as any set of placed members is charged.
local function spellingOf(state, members, present, seat, waiting)
  local placed = {}
  for slot, position in ipairs(present) do
    placed[members[position]] = { coords    = state.at[slot].coords,
                                  component = state.at[slot].component }
  end

  local springs, box = chargeOf(members, seat, placed)
  return { box = box, springs = springs, waiting = util.clone(waiting), placed = placed }
end

-- A waiting member states no interval, so the beam runs once per set of members left
-- waiting; a deferral is no rival to a spelling, so the cut runs within a set (§ The candidates).
--shape: Spelling = { box=<what its components carry>, springs={Spring,..}, waiting={member,..}, placed={ [strand]={ coords=Coords, component } } }
--contract: members; seat/window/mayWait per strand; moves, width, stiffness → Spellings, best first
--contract: a join is one move, landing within two half-windows of the member's own seat
--contract: the width is a width per waiting set; math.huge enumerates the spellings whole
--contract: a sonority some member no chain reaches has no spelling: the list comes back empty
function sonority.spellings(members, seat, window, mayWait, moves, width, stiffness)
  local waiters = {}
  for position = 1, #members do
    if mayWait[members[position]] then util.add(waiters, position) end
  end

  local found = {}
  for choice = 0, (1 << #waiters) - 1 do
    local waits = {}
    for bit, position in ipairs(waiters) do
      if (choice >> (bit - 1)) & 1 == 1 then waits[position] = true end
    end

    local present, seats, windows, waiting = {}, {}, {}, {}
    for position = 1, #members do
      if waits[position] then
        util.add(waiting, members[position])
      else
        util.add(present, position)
        util.add(seats,   seat[members[position]])
        util.add(windows, window[members[position]])
      end
    end

    for _, state in ipairs(beamOver(seats, windows, moves, width, stiffness)) do
      util.add(found, { state = state, present = present, waiting = waiting,
                        waitKey = util.key(table.unpack(waiting)) })
    end
  end

  table.sort(found, function(a, b)
    if a.state.score ~= b.state.score then return a.state.score < b.state.score end
    if a.state.key   ~= b.state.key   then return a.state.key   < b.state.key   end
    return a.waitKey < b.waitKey
  end)

  local spellings = {}
  for k, entry in ipairs(found) do
    spellings[k] = spellingOf(entry.state, members, entry.present, seat, entry.waiting)
  end
  return spellings
end

----- The terms

-- One window serves a strand in every register, so notes[1] speaks for all of them; the
-- seat keeps the register it was written in, which tuning.gapTo quotients out again.
--contract: strands, notation → the cents of each strand's written step, and its window either side
function sonority.seats(strands, notation)
  local seat, window = {}, {}
  for index, strand in ipairs(strands) do
    local cents, below, above = tuning.seatWindow(notation, strand.notes[1])
    seat[index]   = cents
    window[index] = { below = below, above = above }
  end
  return seat, window
end

-- A member is free to wait while an onset it sounds through is still to come; at that onset
-- it places or the state fails (design/adaptive-springs.md § The candidates).
--shape: Onset = { ppq, members={strand,..}, sounding={strand,..}, mayWait={[strand]=true,..} }
--contract: strands, sonorities → an Onset per sonority, its members the walk's own
--contract: a member the sonority holds by recency has stopped: it neither sounds nor waits
function sonority.onsets(strands, sonorities)
  local onsets = {}
  for i, current in ipairs(sonorities) do
    local live = {}
    for _, index in ipairs(current.strands) do
      if sounding(strands[index], current.ppq) then util.add(live, index) end
    end
    onsets[i] = { ppq = current.ppq, members = current.strands, sounding = live, mayWait = {} }
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

-- The strands a later onset names, which is all a continuation can read of an answer:
-- what nothing ahead names is settled, however the answer arrived at it.
local function visibleAhead(onsets)
  local ahead, seen = {}, {}
  for i = #onsets, 1, -1 do
    ahead[i] = util.clone(seen)
    for _, index in ipairs(onsets[i].members) do seen[index] = true end
  end
  return ahead
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
    local group = groups[component]
    for _, member in ipairs(group) do
      util.add(parts, member)
      util.add(parts, coordString(rebase(placed[member].coords, placed[group[1]].coords, {})))
    end
    util.add(parts, '/')
  end

  local held = util.keys(waiting)
  table.sort(held)
  for _, member in ipairs(held) do util.add(parts, member) end
  return util.key(table.unpack(parts))
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
-- ahead rounded to where two of them stop being two, and the deferrals it has yet to pay.
local function answerKey(displacement, ahead, onsets, held)
  local indices = util.keys(ahead)
  table.sort(indices)

  local parts = {}
  for _, index in ipairs(indices) do
    util.add(parts, index)
    util.add(parts, util.round(displacement[index], AUDIBLE))
  end

  local owed = util.keys(held)
  table.sort(owed)
  for _, onset in ipairs(owed) do
    local entry = held[onset]
    util.add(parts, onset)
    for _, member in ipairs(onsets[onset].members) do
      local at = entry.placed[member]
      util.add(parts, at and tokenOf(at) or (entry.waiting[member] and '?' or ''))
    end
  end
  return util.key(table.unpack(parts))
end

-- What a spelling makes of a sonority still waiting: a waiter it places takes coords in the
-- held sonority's frame through a member the two share, alone where they share none.
--invariant: a waiter reaching two components merges them, every member shifted into the one frame
local function complete(entry, members, spelling)
  local placed, waiting, free = util.clone(entry.placed), util.clone(entry.waiting), entry.next
  local landed = false

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
      waiting[member] = nil
      landed = true

      if #hosts == 0 then
        placed[member] = { coords = {}, component = free }
        free = free + 1
      else
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
  end
  return placed, waiting, free, landed
end

-- The entry a spelling that defers opens: what it placed, whom it left, and what it has
-- been charged so far, with the first component id its waiters may stand alone under.
local function heldBy(spelling)
  local waiting, free = {}, 1
  for _, member in ipairs(spelling.waiting) do waiting[member] = true end
  for _, at in pairs(spelling.placed) do free = math.max(free, at.component + 1) end
  return { placed = spelling.placed, waiting = waiting, box = spelling.box, next = free }
end

-- One answer extended by one spelling: the springs and box it has paid, each sonority it
-- still holds charged again for what this spelling places, the onset's own strands relaxed.
--contract: nil where a wait comes back with a placement its own sonority offered (§ The candidates)
local function extend(answer, spelling, onsets, at, seat, window, strength, stiffness, offered)
  local springs, held = util.clone(answer.springs), {}
  local box = answer.box + spelling.box
  springs[at] = spelling.springs

  for onset = 1, at - 1 do
    local entry = answer.held[onset]
    if entry then
      local members = onsets[onset].members
      local placed, waiting, free, landed = complete(entry, members, spelling)
      if landed and offered[onset][placementKey(members, placed, waiting)] then return nil end

      local charged, widened = chargeOf(members, seat, placed)

      springs[onset] = charged
      box = box - entry.box + widened
      if next(waiting) then
        held[onset] = { placed = placed, waiting = waiting, box = widened, next = free }
      end
    end
  end
  if #spelling.waiting > 0 then held[at] = heldBy(spelling) end

  local displacement = sonority.relax(springs, window, strength, stiffness,
                                      answer.displacement, onsets[at].sounding)
  return { choice = util.clone(answer.choice), springs = springs, box = box, held = held,
           displacement = displacement,
           cost = box + sonority.springCost(springs, displacement, window,
                                            strength, stiffness) }
end

-- The cost is taken over every spring accumulated so far rather than the onset's own, so
-- a spelling is priced against the past it is chosen behind (§ The solve).
--shape: Answer = { choice={ spelling per onset }, springs={ Spring list per onset }, box, displacement, cost, held={ [onset]=Held } }
--shape: Held = { placed={ [strand]={ coords=Coords, component } }, waiting={ [strand]=true }, box=<charged so far>, next=<free component> }
--contract: onsets, a spelling list per onset, seat and window per strand, strength, stiffness, cap
--contract: → the cheapest Answer, every answer carried extended by every spelling of the onset
--contract: the strands the onset sounds relax; the rest of an answer stands at the cents it carries
--contract: a sonority holding a waiter is charged in its own onset's slot, as its members place
--contract: answers agreeing to half a cent ahead and owing the same merge; the set is cut to cap
--contract: the cut runs over two pools, the answers that owe and the answers that have paid
--contract: nil where an onset has no spelling — a sonority the target can't reach refuses it
function sonority.search(onsets, spellings, seat, window, strength, stiffness, cap)
  local ahead, start, offered = visibleAhead(onsets), {}, offeredBy(onsets, spellings)
  for index = 1, #window do start[index] = 0 end
  local answers = { { choice = {}, springs = {}, box = 0, displacement = start, cost = 0,
                      held = {} } }

  for i = 1, #onsets do
    local reached = {}
    for _, answer in ipairs(answers) do
      for choice, spelling in ipairs(spellings[i]) do
        local state = extend(answer, spelling, onsets, i, seat, window, strength, stiffness,
                             offered)
        if state then
          state.choice[i] = choice

          local key = answerKey(state.displacement, ahead[i], onsets, state.held)
          if outranks(state, reached[key], i, byChoice) then reached[key] = state end
        end
      end
    end

    -- A deferral moves charge out of the running score rather than paying it, so a road that
    -- owes is cut among the roads that owe, and never against one that has paid (§ The solve).
    local paid, owing = {}, {}
    for _, state in pairs(reached) do util.add(next(state.held) and owing or paid, state) end

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

-- The moves facility's solve: the target read as intervals between strands rather than
-- as points. The lattice search that stood here is retired, and the springs solve lands
-- in its place (design/adaptive-springs.md § Where it sits).
--contract: strands, n, strength, notation, moves → nil, until the springs solve lands
function sonority.solveToMoves(strands, n, strength, notation, moves)
  return nil
end

return sonority
