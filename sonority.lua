-- The objective an adaptive-tuning solve minimises.
-- See design/adaptive-tuning.md § What "in tune" means.
-- @noindex

--invariant: pure module: no module state, no ratios, no cents — coords in, a number out
--shape: Coords = {[oddPrime]=exponent}; prime 2 is absent, so the score reads harmony not spacing
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

return sonority
