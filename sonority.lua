-- The objective an adaptive-tuning solve minimises.
-- See design/adaptive-tuning.md § What "in tune" means.
-- @noindex

--invariant: pure module: no state, no ratios, no cents — coords, strikes, classes in, indices out
--shape: Coords = {[oddPrime]=exponent}; prime 2 is absent, so the score reads harmony not spacing
--shape: Strand = { notes={ {ppq,pitch,..},.. }, class=<step-class>, shortlist={ Candidate,.. } }; the walk reads the strikes and the class only
--shape: Sonority = { ppq, strands={ strandIndex,.. } }; most recently struck first, at most n entries

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

return sonority
