-- The objective an adaptive-tuning solve minimises.
-- See design/adaptive-tuning.md § What "in tune" means.
-- @noindex

--invariant: pure module: no state, no ratios, no cents — coords, strikes, classes in, indices out
--shape: Coords = {[oddPrime]=exponent}; prime 2 is absent, so the score reads harmony not spacing
--shape: Strand = { notes={ {ppq,pitch,..},.. }, class=<step-class>, shortlist={ Candidate,.. } }; the walk reads the strikes and the class only
--shape: Sonority = { ppq, strands={ strandIndex,.. } }; most recently struck first, at most n entries
--shape: Candidate = { coords=Coords, strain=<distance from the written step, in half-windows> }

local util = require 'util'
local sonority = {}

----- The box

-- log₂ p, the ear's distance to a prime; memoised, the solve scoring in its inner loop.
local weights = {}
local function weight(prime)
  local w = weights[prime]
  if not w then w = math.log(prime, 2); weights[prime] = w end
  return w
end

-- The axes are gathered before any is measured: a member holding no exponent on
-- an axis sits at 0 there, and that 0 is only in the span once the axis is known
-- to exist — an axis every member names does not reach back to the origin.
--contract: coords[] → Σ over the odd primes of (highest exponent − lowest) × log₂ p
function sonority.score(coordSet)
  local primes = {}
  for _, coords in ipairs(coordSet) do
    for prime in pairs(coords) do primes[prime] = true end
  end
  local total = 0
  for prime in pairs(primes) do
    local high, low = coordSet[1][prime] or 0, coordSet[1][prime] or 0
    for i = 2, #coordSet do
      local exponent = coordSet[i][prime] or 0
      if exponent > high then high = exponent end
      if exponent < low  then low  = exponent end
    end
    total = total + (high - low) * weight(prime)
  end
  return total
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

-- The class holds one entry however many notes write it: a restrike moves its
-- own entry to the front, and a second strand of the class takes the entry over.
local function promote(recent, strands, index)
  local class = strands[index].class
  for k = 1, #recent do
    if strands[recent[k]].class == class then table.remove(recent, k); break end
  end
  table.insert(recent, 1, index)
end

-- The whole onset is absorbed before the window is trimmed, so a chord wider
-- than n leaves its own lowest notes standing rather than its predecessor's.
--contract: strands, n → a Sonority per distinct onset, the last n distinct classes struck so far
function sonority.walk(strands, n)
  local strikes, sonorities, recent, at = strikesInOrder(strands), {}, {}, 1
  while at <= #strikes do
    local ppq = strikes[at].ppq
    while at <= #strikes and strikes[at].ppq == ppq do
      promote(recent, strands, strikes[at].strand)
      at = at + 1
    end
    for k = #recent, n + 1, -1 do recent[k] = nil end
    local current = util.clone(recent)
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

local function keyOf(choice, list)
  local parts = {}
  for k, index in ipairs(list) do parts[k] = choice[index] end
  return util.key(table.unpack(parts))
end

-- The state carries the whole choice vector rather than a backpointer: two
-- generations are alive at a time and the budget bounds them.
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
      local key  = keyOf(state.choice, onset.held)
      local best = carried[key]
      if not best or state.cost < best.cost then carried[key] = state end
    end

    -- Every member of this sonority is now assigned: born here, or live from
    -- before and still carrying what it chose then.
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
        local key  = keyOf(choice, onset.live)
        local best = reached[key]
        if not best or cost < best.cost then reached[key] = { cost = cost, choice = choice } end
      end
    end
    states = reached
  end

  local best
  for _, state in pairs(states) do
    if not best or state.cost < best.cost then best = state end
  end
  return best.choice
end

return sonority
