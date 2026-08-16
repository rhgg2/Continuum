-- See docs/tuning.md for the model.
-- @noindex

--invariant: pure coordinate-system module: no module state, no take state, no pb / detune realisation logic
--invariant: intent / realisation split — owns intent (cents-typed detune); pb realisation is tm's domain
--invariant: detune is cents throughout; raw 14-bit pb conversion is tm's flush boundary, never here
--invariant: cents[1] is the unison (0); nameless step displays as degree-octave via stepToParts
--invariant: an octave is period-index + octaveBase; default root makes it MIDI-relative (C4 → 4)
--shape: Temper = {name, periodPitch=token, pitches=token[ascending], stepNames=string[], periodAsStep=bool, rootPitch=int?, rootDetune=cents?, rootStep=int?, rootOctave=int?, cents=number[derived], period=cents[derived], rootCents=cents[derived], octaveBase=int[derived], octaveStep=int, octaveWidth=int, cellWidth=int}
local util = require 'util'

local tuning = {}

----- Temperament presets

-- octaveStep: first step whose label reads as the next octave's C. Scans from
-- the end for the last non-C name; nameless scale → bump at period (n+1).
local function computeOctaveStep(stepNames, n)
  for i = n, 1, -1 do
    local nm = stepNames[i]
    if nm and nm ~= '' and nm:sub(1, 1) ~= 'C' then return i + 1 end
  end
  return n + 1
end

-- A negative octave renders as its magnitude, for the caller to tint — the
-- sign costs no column. See docs/tuning.md § Display.
local function octaveLabel(o)
  return tostring(math.abs(o))
end

-- octaveFieldWidth: char width of the octave field, sized on the octave
-- numbers at both ends of the range the root opens. See docs/tuning.md § Display.
local function octaveFieldWidth(temper)
  local period = temper.period
  local bottom = math.floor(-temper.rootCents / period) + temper.octaveBase
  local top    = math.floor((12700 - temper.rootCents) / period) + temper.octaveBase
  return math.max(#octaveLabel(bottom), #octaveLabel(top))
end

-- rootCents: where the scale's unison sits in sound, given the root's four
-- authored fields. See docs/tuning.md § The root.
local function computeRootCents(temper)
  local pitch, detune = temper.rootPitch or 0, temper.rootDetune or 0
  return pitch * 100 + detune - temper.cents[temper.rootStep or 1]
end

-- cellWidth: widest step label + the octave field; see docs/tuning.md § Display.
local function computeCellWidth(temper)
  local stepNames, n = temper.stepNames or {}, #temper.cents
  local widest = 0
  for i = 1, n do
    local nm   = stepNames[i]
    local base = (nm and nm ~= '') and utf8.len(nm) or (#tostring(i) + 1)
    if base > widest then widest = base end
  end
  return widest + octaveFieldWidth(temper)
end

--contract: token → cents or nil: n/d, int, '.'=cents, n\m, n\m<equave> step (equave dflt 2/1).
function tuning.scalaPitch(token)
  token = token:match('^%s*(.-)%s*$')
  -- n\m<equave>: n of m equal divisions of equave (default the octave 2/1).
  local steps, div, equave = token:match('^(%d+)\\(%d+)<(.-)>$')
  if not steps then steps, div = token:match('^(%d+)\\(%d+)$') end
  if steps then
    local span = 1200
    if equave then
      span = tuning.scalaPitch(equave)
      if not span then return nil end
    end
    return tonumber(steps) * span / tonumber(div)
  end
  if token:find('%.') then return tonumber(token) end
  local a, b = token:match('^(%d+)/(%d+)$')
  if a then return 1200 * math.log(tonumber(a) / tonumber(b), 2) end
  if token:match('^%d+$') then return 1200 * math.log(tonumber(token), 2) end
  return nil
end

--contract: pitches→cents, periodPitch→period; stamps root/octave/cell fields. Pure; returns temper.
function tuning.derive(temper)
  if temper.pitches then
    local cents = {}
    for i, tok in ipairs(temper.pitches) do cents[i] = tuning.scalaPitch(tok) or 0 end
    temper.cents = cents
  end
  if temper.periodPitch then
    temper.period = tuning.scalaPitch(temper.periodPitch) or temper.period
  end
  local n = #temper.cents
  temper.octaveStep  = computeOctaveStep(temper.stepNames or {}, n)
  temper.rootCents   = computeRootCents(temper)
  temper.octaveBase  = temper.rootOctave or -1
  temper.octaveWidth = octaveFieldWidth(temper)
  temper.cellWidth   = computeCellWidth(temper)
  return temper
end

-- The root's step is gone: restate it on the unison, at the rootCents standing before the
-- edit — the same tuning, written at the one step every scale keeps.
local function restateOnUnison(temper)
  local pitch = math.min(127, math.max(0, math.floor(temper.rootCents / 100 + 0.5)))
  temper.rootStep, temper.rootPitch = 1, pitch
  temper.rootDetune = temper.rootCents - pitch * 100
end

--contract: sort (pitches, stepNames) ascending by compiled cents, rootStep riding with its step
function tuning.sortSteps(temper)
  local rows = {}
  for i, tok in ipairs(temper.pitches) do
    rows[i] = { tok = tok, nm = temper.stepNames[i] or '', c = tuning.scalaPitch(tok) or 0,
                rooted = i == temper.rootStep }
  end
  table.sort(rows, function(a, b) return a.c < b.c end)
  for i, row in ipairs(rows) do
    temper.pitches[i]   = row.tok
    temper.stepNames[i] = row.nm
    if row.rooted then temper.rootStep = i end
  end
  return temper
end

--contract: drop step i, the root following the step it names; a root on i restates on the unison
function tuning.removeStep(temper, i)
  table.remove(temper.pitches, i)
  table.remove(temper.stepNames, i)
  if temper.rootStep == i then restateOnUnison(temper)
  elseif temper.rootStep and temper.rootStep > i then temper.rootStep = temper.rootStep - 1 end
  return temper
end

--contract: copy with the four root fields dropped and stamps refreshed at the default root
function tuning.unrooted(temper)
  local out = util.deepClone(temper)
  out.rootPitch, out.rootDetune, out.rootStep, out.rootOctave = nil, nil, nil, nil
  return tuning.derive(out)
end

local function edo(n, names)
  local pitches = {}
  for i = 1, n do pitches[i] = (i - 1) .. '\\' .. n end
  return tuning.derive{
    name        = n .. 'EDO',
    periodPitch = '2/1',
    pitches     = pitches,
    stepNames   = names,
  }
end

tuning.presets = {
  ['12EDO'] = edo(12, {
    'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'
  }),
  ['19EDO'] = edo(19, {
    'C-','C#','Db','D-','D#','Eb','E-','E#','F-','F#','Gb',
    'G-','G#','Ab','A-','A#','Bb','B-','B#'
  }),
  ['31EDO'] = edo(31, {
    'C-','C↑','C#','Db','D↓','D-','D↑','D#','Eb','E↓','E-',
    'E↑','F↓','F-','F↑','F#','Gb','G↓','G-','G↑','G#','Ab',
    'A↓','A-','A↑','A#','Bb','B↓','B-','B↑','C↓'
  }),
  ['53EDO'] = edo(53, {
    'C-','C↑','C⇑','C⇈','Db','C#','D⇊','D⇓','D↓','D-','D↑',
    'D⇑','D⇈','Eb','D#','E⇊','E⇓','E↓','E-','E↑','E⇑','F↓',
    'F-','F↑','F⇑','F⇈','Gb','F#','G⇊','G⇓','G↓','G-','G↑',
    'G⇑','G⇈','Ab','G#','A⇊','A⇓','A↓','A-','A↑','A⇑','A⇈',
    'Bb','A#','B⇊','B⇓','B↓','B-','B↑','B⇑','C↓'
  }),
}

--contract: userLib first, then presets; nil when unknown to both; '12EDO' resolves via presets
function tuning.findTemper(name, userLib)
  if not name then return nil end
  return (userLib and userLib[name]) or tuning.presets[name]
end

----- Scala import

-- Lenient: every non-blank, non-'!' line is a pitch token. Drives paste + the
-- import Create button (which re-parses the box after any manual edits).
function tuning.parseScalaPitches(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    local s = line:match('^%s*(.-)%s*$')
    if s ~= '' and s:sub(1, 1) ~= '!' then util.add(lines, s) end
  end
  return lines
end

-- Strict .scl: drop '!' comment lines, then [description, count, pitch x count].
-- Returns pitch tokens + description (suggested name) for the Scala load path.
function tuning.parseScalaFile(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    if not line:match('^%s*!') then util.add(lines, line) end
  end
  local description = (lines[1] or ''):match('^%s*(.-)%s*$')
  local count       = tonumber((lines[2] or ''):match('%d+'))
  local pitches     = {}
  for i = 3, #lines do
    local s = lines[i]:match('^%s*(.-)%s*$')
    if s ~= '' then util.add(pitches, s) end
    if count and #pitches >= count then break end
  end
  return pitches, description
end

-- Bridge Scala's convention (unison implicit, period last) to Continuum's
-- (step 1 = 1/1, period separate): prepend unison, split off final as period.
function tuning.scalaToTemper(pitchLines, name)
  if #pitchLines == 0 then return nil, 'no pitches' end
  for _, tok in ipairs(pitchLines) do
    if not tuning.scalaPitch(tok) then return nil, ('unparseable pitch: %q'):format(tok) end
  end
  -- Sort ascending so the widest interval is the period and cents stay
  -- monotonic regardless of paste order (a well-formed .scl is already sorted).
  local sorted = { table.unpack(pitchLines) }
  table.sort(sorted, function(a, b) return tuning.scalaPitch(a) < tuning.scalaPitch(b) end)
  local pitches = { '1/1' }
  for i = 1, #sorted - 1 do util.add(pitches, sorted[i]) end
  return tuning.derive{
    name         = name,
    periodPitch  = sorted[#sorted],
    pitches      = pitches,
    stepNames    = {},
    periodAsStep = true,
  }
end

----- Generators

-- Equal-division subset spec -> ascending degrees; largest is the period.
-- 'relative': cumulative step counts. 'absolute': sorted+deduped. nil on bad token.
function tuning.edoDegrees(spec, mode)
  local nums = {}
  for tok in spec:gmatch('%S+') do
    local n = tonumber(tok)
    if not n or n ~= math.floor(n) or n < 1 then return nil end
    util.add(nums, n)
  end
  if #nums == 0 then return nil end
  if mode == 'relative' then
    local degs, acc = {}, 0
    for _, step in ipairs(nums) do acc = acc + step; util.add(degs, acc) end
    return degs
  end
  table.sort(nums)
  local degs = {}
  for _, d in ipairs(nums) do if degs[#degs] ~= d then util.add(degs, d) end end
  return degs
end

-- Inverse of edoDegrees: render a degree list back as a spec string in `mode`.
-- Lets a mode switch convert the in-flight pattern rather than reset it.
function tuning.degreesToSpec(degrees, mode)
  if mode == 'absolute' then return table.concat(degrees, ' ') end
  local steps, prev = {}, 0
  for _, d in ipairs(degrees) do util.add(steps, d - prev); prev = d end
  return table.concat(steps, ' ')
end

-- N-equal-divisions of `interval` subset to `degrees`; tokens are intensional
-- (d\D<equave>, suffix omitted for octave). Base 0 implicit; last degree = period.
function tuning.genEqual(degrees, interval)
  local D      = degrees[#degrees]
  local suffix = (interval and interval ~= '' and interval ~= '2/1') and ('<' .. interval .. '>') or ''
  local pitches = { '0\\' .. D .. suffix }
  for i = 1, #degrees - 1 do pitches[i + 1] = degrees[i] .. '\\' .. D .. suffix end
  return { pitches = pitches, periodPitch = D .. '\\' .. D .. suffix, periodAsStep = true }
end

-- Harmonic-series segment lo..hi: ratios m/lo rooted on the low harmonic, the
-- top (hi/lo) the period.
function tuning.genHarmonics(lo, hi)
  local pitches = {}
  for m = lo, hi - 1 do util.add(pitches, m .. '/' .. lo) end
  return { pitches = pitches, periodPitch = hi .. '/' .. lo, periodAsStep = true }
end

-- Subharmonic (utonal) segment lo..hi: ratios hi/m ascending, top the period.
function tuning.genSubharmonics(lo, hi)
  local pitches = {}
  for m = hi, lo + 1, -1 do util.add(pitches, hi .. '/' .. m) end
  return { pitches = pitches, periodPitch = hi .. '/' .. lo, periodAsStep = true }
end

-- Colon/space-separated extended ratio (e.g. '4:5:6:7') -> positive integers,
-- at least two. nil + message otherwise.
function tuning.parseChord(spec)
  local members = {}
  for tok in spec:gmatch('[^%s:]+') do
    local n = tonumber(tok)
    if not n or n ~= math.floor(n) or n < 1 then return nil, 'chord needs whole numbers' end
    util.add(members, n)
  end
  if #members < 2 then return nil, 'chord needs at least two notes' end
  return members
end

-- Enumerate a chord as a scale rooted on its first note. otonal: ci/c1.
-- inverted (utonal): ck/c(k+1-i). The last member is the period either way.
function tuning.genChord(members, invert)
  local k, c1, ck = #members, members[1], members[#members]
  local pitches = {}
  for i = 1, k - 1 do
    pitches[i] = invert and (ck .. '/' .. members[k + 1 - i]) or (members[i] .. '/' .. c1)
  end
  return { pitches = pitches, periodPitch = ck .. '/' .. c1, periodAsStep = true }
end

local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end

-- Every k-subset of 1..n as a list of 1-based index lists.
local function combinations(n, k)
  local out, idx = {}, {}
  local function rec(start, depth)
    if depth > k then util.add(out, { table.unpack(idx) }); return end
    for i = start, n do idx[depth] = i; rec(i + 1, depth + 1) end
  end
  rec(1, 1)
  return out
end

-- Combination product set: every k-subset's product, rooted on the smallest
-- product (so 1/1 is always present) and reduced into the equave; ascending.
function tuning.genCPS(factors, k, equave)
  equave = equave or '2/1'
  local ea, eb = equave:match('^(%d+)/(%d+)$')
  if not ea then ea, eb = equave:match('^(%d+)$'), '1' end
  ea, eb = tonumber(ea), tonumber(eb)
  local products = {}
  for _, subset in ipairs(combinations(#factors, k)) do
    local p = 1
    for _, i in ipairs(subset) do p = p * factors[i] end
    util.add(products, p)
  end
  local root = products[1]
  for _, p in ipairs(products) do if p < root then root = p end end
  local tokens = {}
  for j, p in ipairs(products) do
    local num, den = p, root
    while num * eb >= den * ea do num, den = num * eb, den * ea end
    while num < den do num, den = num * ea, den * eb end
    local g = gcd(num, den)
    num, den = num // g, den // g
    tokens[j] = num .. '/' .. den
  end
  table.sort(tokens, function(x, y) return tuning.scalaPitch(x) < tuning.scalaPitch(y) end)
  return { pitches = tokens, periodPitch = equave, periodAsStep = true }
end

-- Check if every prime factor of the odd `n` is at or below `limit`.
local function primeFactorsBelow(n, limit)
  local p = 3
  while p * p <= n do
    if n % p == 0 then
      if p > limit then return false end
      repeat n = n // p until n % p ~= 0
    end
    p = p + 2
  end
  return n <= limit
end

-- N-odd-limit tonality diamond: coprime odd pairs to `oddLimit`, reduced into the
-- octave; `primeLimit` filters larger primes. See design/adaptive-tuning.md § The diamond.
function tuning.genDiamond(oddLimit, primeLimit)
  primeLimit = primeLimit or oddLimit
  local tokens = {}
  for a = 1, oddLimit, 2 do
    for b = 1, oddLimit, 2 do
      if gcd(a, b) == 1 and primeFactorsBelow(a, primeLimit) and primeFactorsBelow(b, primeLimit) then
        local num, den = a, b
        while num >= den * 2 do den = den * 2 end
        while num < den do num = num * 2 end
        util.add(tokens, num .. '/' .. den)
      end
    end
  end
  table.sort(tokens, function(x, y) return tuning.scalaPitch(x) < tuning.scalaPitch(y) end)
  return { pitches = tokens, periodPitch = '2/1', periodAsStep = true }
end

-- Reduce a cents value into [0, period).
local function reduceCents(c, period)
  return c - period * math.floor(c / period)
end

local function asRatio(token)
  local n, d = token:match('^(%d+)/(%d+)$')
  if n then return tonumber(n), tonumber(d) end
  if token:match('^%d+$') then return tonumber(token), 1 end
  return nil
end

-- gn/gd stacked k times (k may be negative), reduced into the period pn/pd
-- as a lowest-terms ratio. nil if exact integers would overflow (~2^40).
local RATIO_CAP = 1 << 40
local function stackRatio(gn, gd, pn, pd, k)
  local num, den = 1, 1
  local mn, md = (k >= 0) and gn or gd, (k >= 0) and gd or gn
  for _ = 1, math.abs(k) do
    num, den = num * mn, den * md
    if num > RATIO_CAP or den > RATIO_CAP then return nil end
  end
  while num * pd >= den * pn do num, den = num * pd, den * pn end
  while num < den do num, den = num * pn, den * pd end
  local g = gcd(num, den)
  return num // g, den // g
end

-- Adjacent step sizes (incl. the wrap step) of an n-note chain of `g`
-- reduced into `p`: {cents, count} per distinct size, large first.
local function stepSpectrum(g, p, n)
  local pts = {}
  for k = 0, n - 1 do util.add(pts, reduceCents(k * g, p)) end
  table.sort(pts)
  local sizes = {}
  for i = 1, n do
    local step = ((i < n) and pts[i + 1] or p) - pts[i]
    local slot
    for _, s in ipairs(sizes) do if math.abs(s.cents - step) < 1e-6 then slot = s; break end end
    if slot then slot.count = slot.count + 1
    else util.add(sizes, { cents = step, count = 1 }) end
  end
  table.sort(sizes, function(a, b) return a.cents > b.cents end)
  return sizes
end

-- Rank-2 scale: stack the generator `up` above and `size-1-up` below 1/1,
-- reduce into period, sort. up = mode. Exact ratios if inputs rational, else cents.
function tuning.genRank2(generator, period, size, up)
  period = period or '2/1'
  local down = size - 1 - up
  local gn, gd = asRatio(generator)
  local pn, pd = asRatio(period)
  local g, p = tuning.scalaPitch(generator), tuning.scalaPitch(period)
  local entries = {}
  for k = -down, up do
    local num, den
    if gn and pn then num, den = stackRatio(gn, gd, pn, pd, k) end
    local cents = num and 1200 * math.log(num / den, 2) or reduceCents(k * g, p)
    local token = num and (num .. '/' .. den)
                  or ((cents < 1e-6) and '1/1' or string.format('%.4f', cents))
    util.add(entries, { cents = cents, token = token })
  end
  table.sort(entries, function(a, b) return a.cents < b.cents end)
  local pitches = {}
  for i, e in ipairs(entries) do pitches[i] = e.token end
  return { pitches = pitches, periodPitch = period, periodAsStep = true }
end

--contract: {isMos, large, small} for an n-note chain; large/small are L/s step counts when isMos
function tuning.mosInfo(generator, period, n)
  local spec = stepSpectrum(tuning.scalaPitch(generator), tuning.scalaPitch(period or '2/1'), n)
  if #spec ~= 2 then return { isMos = false } end
  return { isMos = true, large = spec[1].count, small = spec[2].count }
end

--contract: next MOS size (two step sizes) from fromN, stepping dir (+/-1); nil past the cap
function tuning.nextMosSize(generator, period, fromN, dir)
  local g, p = tuning.scalaPitch(generator), tuning.scalaPitch(period or '2/1')
  local n = fromN + dir
  while n >= 2 and n <= 400 do
    if #stepSpectrum(g, p, n) == 2 then return n end
    n = n + dir
  end
  return nil
end

local OCTAVE = 1200

-- Slack on the reach a widened window takes, in half-windows.
local REACH_TOL = 1e-9

----- Coordinate conversions

--contract: detune optional (defaults 0); snaps to nearest scale point including the period boundary (rounds up to step 1 of next octave)
--contract: returned octave is period-index + temper.octaveBase (at the default root, C-1 → -1)
function tuning.midiToStep(temper, midi, detune)
  detune = detune or 0
  local cents  = midi * 100 + detune - temper.rootCents
  local period = temper.period
  local octave = math.floor(cents / period)
  local res    = cents - octave * period
  local steps  = temper.cents

  local best, bestDist = 1, math.abs(res - steps[1])
  for i = 2, #steps do
    local d = math.abs(res - steps[i])
    if d < bestDist then best, bestDist = i, d end
  end
  -- Step 1 of the next period sits at cents = period.
  if math.abs(res - period) < bestDist then
    best, octave = 1, octave + 1
  end

  return best, octave + temper.octaveBase
end

--contract: wraps out-of-range step by adjusting octave; clamps midi to 0..127 by folding overflow into detune (never silently drops)
function tuning.stepToMidi(temper, step, octave)
  local steps, n = temper.cents, #temper.cents
  while step < 1 do step = step + n; octave = octave - 1 end
  while step > n do step = step - n; octave = octave + 1 end

  local cents  = (octave - temper.octaveBase) * temper.period + steps[step] + temper.rootCents
  local midi   = math.floor(cents / 100 + 0.5)
  local detune = cents - midi * 100

  if midi < 0 then
    detune, midi = detune + 100 * midi, 0
  elseif midi > 127 then
    detune, midi = detune + 100 * (midi - 127), 127
  end

  return midi, detune
end

function tuning.snap(temper, midi, detune)
  return tuning.stepToMidi(temper, tuning.midiToStep(temper, midi, detune))
end

-- The step a note is written on, taken modulo the octave the score quotients
-- out. See design/adaptive-tuning.md § The model.
--contract: the note's written seat reduced into the octave; an octave apart answers alike
function tuning.stepClass(temper, midi, detune)
  local seatMidi, seatDetune = tuning.snap(temper, midi, detune)
  return util.round(reduceCents(seatMidi * 100 + seatDetune, OCTAVE), 1e-6)
end

--contract: half-gaps in cents to steps below/above `step`; both positive, wraps the period
function tuning.stepWindow(temper, step)
  local steps, n = temper.cents, #temper.cents
  local period   = temper.period
  local below    = step == 1 and steps[n] - period or steps[step - 1]
  local above    = step == n and steps[1] + period or steps[step + 1]
  return (steps[step] - below) / 2, (above - steps[step]) / 2
end

--contract: moves by n scale steps under temper, carrying the octave; n may be negative
function tuning.transposeStep(temper, midi, detune, n)
  local step, oct = tuning.midiToStep(temper, midi, detune)
  return tuning.stepToMidi(temper, step + n, oct)
end

--contract: signed count of whole temper steps from note a to note b, each snapped to nearest step
function tuning.stepsBetween(temper, aMidi, aDetune, bMidi, bDetune)
  local aStep, aOct = tuning.midiToStep(temper, aMidi, aDetune)
  local bStep, bOct = tuning.midiToStep(temper, bMidi, bDetune)
  return (bOct - aOct) * #temper.cents + (bStep - aStep)
end

----- Targets

-- The odd primes of `n` accumulated into `coords` at `sign`. Twos are divided
-- out first; whatever survives trial division past sqrt(n) is itself a prime.
local function addOddFactors(n, coords, sign)
  while n % 2 == 0 do n = n // 2 end
  local p = 3
  while p * p <= n do
    while n % p == 0 do
      coords[p] = (coords[p] or 0) + sign
      n = n // p
    end
    p = p + 2
  end
  if n > 1 then coords[n] = (coords[n] or 0) + sign end
end

-- Numerator and denominator are factorised apart and their exponents subtracted,
-- so 6/4 and 3/2 read alike and a prime on both sides cancels rather than sitting at zero.
--contract: ratio token -> {[oddPrime]=exponent}, prime 2 divided out; nil for cents or n\m
function tuning.coords(token)
  local num, den = asRatio(token:match('^%s*(.-)%s*$'))
  if not num or num == 0 or den == 0 then return nil end
  local coords = {}
  addOddFactors(num, coords, 1)
  addOddFactors(den, coords, -1)
  for prime, exponent in pairs(coords) do
    if exponent == 0 then coords[prime] = nil end
  end
  return coords
end

-- log₂ p, the ear's distance to a prime; memoised, the solve scoring in its inner loop.
local weights = {}
local function weight(prime)
  local w = weights[prime]
  if not w then w = math.log(prime, 2); weights[prime] = w end
  return w
end

-- Read off the coords, so an unreduced token costs the interval it sounds, not its terms.
-- See design/adaptive-ji.md § What makes the candidate set finite.
--contract: coords → the octave-free Tenney height of the ratio they name: Σ |exponent| × log₂ p
function tuning.height(coords)
  local total = 0
  for prime, exponent in pairs(coords) do
    total = total + math.abs(exponent) * weight(prime)
  end
  return total
end

--contract: true when every pitch of `temper` is a ratio, so its points carry coords to score
function tuning.isTarget(temper)
  for _, token in ipairs(temper.pitches) do
    if not tuning.coords(token) then return false end
  end
  return true
end

-- Coords fix a ratio up to the octave, so they identify a move outright: same coords,
-- same reduced cents. Sorted, so a temper's two spellings of one move key alike.
local function coordKey(coords)
  local primes = util.keys(coords)
  table.sort(primes)
  local parts = {}
  for _, prime in ipairs(primes) do
    util.add(parts, prime)
    util.add(parts, coords[prime])
  end
  return util.key(table.unpack(parts))
end

-- A move set read as intervals from its unison, per design/adaptive-ji.md § Where a move
-- set comes from; an inversion carries the same height, so it sorts beside the move it inverts.
--contract: a ratio temper read as intervals from its unison: {cents, coords, height} per move
--contract: every pitch and its inversion, deduped by coords; cents octave-reduced
--contract: simplest first by height, so the last move states the set's complexity bound
--contract: raises where a pitch is not a ratio, isTarget being what a move set must pass
function tuning.moves(temper)
  if not tuning.isTarget(temper) then
    error('tuning.moves: every pitch of a move set must be a ratio')
  end

  local moves, seen = {}, {}
  local function admit(cents, coords)
    local key = coordKey(coords)
    if seen[key] then return end
    seen[key] = true
    util.add(moves, { cents  = reduceCents(cents, OCTAVE),
                      coords = coords,
                      height = tuning.height(coords) })
  end

  for _, token in ipairs(temper.pitches) do
    local coords  = tuning.coords(token)
    local inverse = {}
    for prime, exponent in pairs(coords) do inverse[prime] = -exponent end
    admit(tuning.scalaPitch(token), coords)
    admit(-tuning.scalaPitch(token), inverse)
  end

  table.sort(moves, function(a, b)
    if a.height ~= b.height then return a.height < b.height end
    return a.cents < b.cents
  end)
  return moves
end

-- The gap from a seat to a point of the octave-reduced line, signed and reduced so a
-- point below the seat reads as a descent, not an ascent; shortlist and seat both use it.
local function gapTo(seat, cents)
  return reduceCents(cents - seat + OCTAVE / 2, OCTAVE) - OCTAVE / 2
end

-- A note's own step: where it seats, and how far its window reaches either side.
-- The shortlist, the reach and the root are all measured off it.
local function seatOf(notation, note)
  local step, octave = tuning.midiToStep(notation, note.pitch, note.detune)
  local midi, detune = tuning.stepToMidi(notation, step, octave)
  local below, above = tuning.stepWindow(notation, step)
  return midi * 100 + detune, below, above
end

-- The only place the notation and the target meet. See design/adaptive-tuning.md
-- § What the solver takes for why the line is reduced into the octave.
--contract: candidates {cents, coords, strain} for the target's points inside the note's step window
--contract: strain is the point's gap over the window half it lies in; nearest first
--contract: widen: where the window holds nothing, the nearest points instead, at strain past 1
function tuning.shortlist(notation, target, keyStep, note, widen)
  local keyCents           = notation.rootCents + notation.cents[keyStep]
  local seat, below, above = seatOf(notation, note)

  local points = {}
  for _, token in ipairs(target.pitches) do
    local cents = reduceCents(keyCents + tuning.scalaPitch(token), OCTAVE)
    local gap   = gapTo(seat, cents)
    local half  = gap < 0 and below or above
    util.add(points, { cents = cents, coords = tuning.coords(token),
                       strain = math.abs(gap) / half })
  end

  -- Strain 1 is the window's own edge; reach stands there until nothing is inside it, then
  -- widens to the nearest point (design/adaptive-tuning.md § What the solver takes).
  local reach = 1
  if widen then
    local nearest = math.huge
    for _, point in ipairs(points) do
      if point.strain < nearest then nearest = point.strain end
    end
    if nearest > reach then reach = nearest end
  end

  local candidates = {}
  for _, point in ipairs(points) do
    if point.strain <= reach + REACH_TOL then util.add(candidates, point) end
  end

  table.sort(candidates, function(a, b)
    if a.strain ~= b.strain then return a.strain < b.strain end
    return a.cents < b.cents
  end)
  return candidates
end

-- The placement's root: the strand seated on the step it was written on, so its strain
-- reads the offset and nothing else (design/adaptive-ji.md § Where a placement sits).
--contract: the root candidate {cents, coords, strain, key} for `note`, its coords empty
--contract: cents is the note's own step seat, on the octave-reduced line a placement lives on
--contract: nil where the offset alone carries the note past its step window
function tuning.origin(notation, note, offset)
  local seat, below, above = seatOf(notation, note)
  local strain             = math.abs(offset) / (offset < 0 and below or above)
  if strain > 1 + REACH_TOL then return nil end
  return { cents = reduceCents(seat, OCTAVE), coords = {},
           strain = strain, key = coordKey({}) }
end

-- Exponents add along an edge of the placement, and a prime cancelling to zero leaves
-- the coords rather than sitting at 0, so coordKey reads two paths to one tuning alike.
local function addCoords(coords, move)
  local sum = {}
  for prime, exponent in pairs(coords) do sum[prime] = exponent end
  for prime, exponent in pairs(move) do
    local total = (sum[prime] or 0) + exponent
    sum[prime] = total ~= 0 and total or nil
  end
  return sum
end

-- The shortlist under a move set: a candidate is one move from a strand already placed, and
-- the offset seats the placement rather than riding along an edge (design/adaptive-ji.md § A placement is connected, § Where a placement sits).
--contract: candidates {cents, coords, strain} one move from an anchor {cents, coords}
--contract: a candidate's coords are the anchor's plus the move's; its cents the placement's own
--contract: kept where `cents + offset` lands inside the note's step window; strain reads it there
--contract: deduped by coords, two anchors reaching one tuning being one candidate; nearest first
--contract: each candidate carries the key it deduped on, so a caller may key on it unrecomputed
function tuning.reach(notation, moves, anchors, note, offset)
  local seat, below, above = seatOf(notation, note)

  local candidates, seen = {}, {}
  for _, anchor in ipairs(anchors) do
    for _, move in ipairs(moves) do
      local cents  = reduceCents(anchor.cents + move.cents, OCTAVE)
      local gap    = gapTo(seat, cents + offset)
      local half   = gap < 0 and below or above
      local strain = math.abs(gap) / half
      if strain <= 1 + REACH_TOL then
        local coords = addCoords(anchor.coords, move.coords)
        local key    = coordKey(coords)
        if not seen[key] then
          seen[key] = true
          util.add(candidates, { cents = cents, coords = coords, strain = strain, key = key })
        end
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.strain ~= b.strain then return a.strain < b.strain end
    return a.cents < b.cents
  end)
  return candidates
end

-- The shortlist's fold in reverse: a point the strand took, in the register of one
-- of the notes that writes it, the note's own step seat being what the window was measured off.
--contract: (pitch, detune) for `cents` placed in the octave nearest the note's seat
function tuning.seat(notation, note, cents)
  local midi, detune = tuning.snap(notation, note.pitch, note.detune)
  local at    = midi * 100 + detune
  local place = at + gapTo(at, cents)
  local pitch = math.floor(place / 100 + 0.5)
  return pitch, place - pitch * 100
end

----- Display

-- The untempered twelve names, for spelling a root — the temper's own naming
-- is what a root fixes, so naming it in-temper would be circular. See docs/tuning.md § The root.
local MIDI_NAMES = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }

--contract: MIDI number → untempered twelve-name spelling (0 → 'C-1', 60 → 'C4')
function tuning.midiName(pitch)
  return MIDI_NAMES[pitch % 12 + 1] .. (math.floor(pitch / 12) - 1)
end

--contract: (note, octaveLabel=|octave|, negative); name or degree+'-'; octave+1 at octaveStep
function tuning.stepToParts(temper, step, octave)
  if step >= temper.octaveStep then octave = octave + 1 end
  local name = temper.stepNames and temper.stepNames[step]
  local note = (name and name ~= '') and name or (step .. '-')
  return note, octaveLabel(octave), octave < 0
end

return tuning
