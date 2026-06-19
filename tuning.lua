-- See docs/tuning.md for the model.
-- @noindex

--invariant: pure coordinate-system module: no module state, no take state, no pb / detune realisation logic
--invariant: intent / realisation split — owns intent (cents-typed detune); pb realisation is tm's domain
--invariant: detune is cents throughout; raw 14-bit pb conversion is tm's flush boundary, never here
--invariant: cents[1] is the unison (0); nameless step displays as degree-octave via M.stepToText
--invariant: octave parameters are MIDI-relative (C4 → 4), not period-index
--shape: Temper = {name, periodPitch=token, pitches=token[ascending], stepNames=string[], periodAsStep=bool, cents=number[derived], period=cents[derived], octaveStep=int, octaveWidth=int, cellWidth=int}
local M = {}

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

-- Octave -1 renders as "M" so the bottom (the cents-0 anchor) stays one char,
-- matching MIDI's C-1. See docs/tuning.md § Addressable range.
local function octaveLabel(o)
  return o == -1 and 'M' or tostring(o)
end

-- octaveFieldWidth: char width of the octave field, fixed by the top of the
-- natural [0,12700]¢ range (floor at -1 ⇒ "M"). See docs/tuning.md § Display.
local function octaveFieldWidth(temper)
  return #octaveLabel(math.floor(12700 / temper.period) - 1)
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
function M.scalaPitch(token)
  token = token:match('^%s*(.-)%s*$')
  -- n\m<equave>: n of m equal divisions of equave (default the octave 2/1).
  local steps, div, equave = token:match('^(%d+)\\(%d+)<(.-)>$')
  if not steps then steps, div = token:match('^(%d+)\\(%d+)$') end
  if steps then
    local span = 1200
    if equave then
      span = M.scalaPitch(equave)
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

--contract: pitches→cents, periodPitch→period; stamps octaveStep + cellWidth. Pure; returns temper.
function M.derive(temper)
  if temper.pitches then
    local cents = {}
    for i, tok in ipairs(temper.pitches) do cents[i] = M.scalaPitch(tok) or 0 end
    temper.cents = cents
  end
  if temper.periodPitch then
    temper.period = M.scalaPitch(temper.periodPitch) or temper.period
  end
  local n = #temper.cents
  temper.octaveStep  = computeOctaveStep(temper.stepNames or {}, n)
  temper.octaveWidth = octaveFieldWidth(temper)
  temper.cellWidth   = computeCellWidth(temper)
  return temper
end

local function edo(n, names)
  local pitches = {}
  for i = 1, n do pitches[i] = (i - 1) .. '\\' .. n end
  return M.derive{
    name        = n .. 'EDO',
    periodPitch = '2/1',
    pitches     = pitches,
    stepNames   = names,
  }
end

M.presets = {
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

--contract: looks up name in userLib first, then falls back to built-in M.presets; returns nil only if name is missing or unknown to both. Lets the '12EDO' sentinel resolve even when userLib is empty.
function M.findTemper(name, userLib)
  if not name then return nil end
  return (userLib and userLib[name]) or M.presets[name]
end

----- Scala import

-- Lenient: every non-blank, non-'!' line is a pitch token. Drives paste + the
-- import Create button (which re-parses the box after any manual edits).
function M.parseScalaPitches(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    local s = line:match('^%s*(.-)%s*$')
    if s ~= '' and s:sub(1, 1) ~= '!' then lines[#lines + 1] = s end
  end
  return lines
end

-- Strict .scl: drop '!' comment lines, then [description, count, pitch x count].
-- Returns pitch tokens + description (suggested name) for the Scala load path.
function M.parseScalaFile(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    if not line:match('^%s*!') then lines[#lines + 1] = line end
  end
  local description = (lines[1] or ''):match('^%s*(.-)%s*$')
  local count       = tonumber((lines[2] or ''):match('%d+'))
  local pitches     = {}
  for i = 3, #lines do
    local s = lines[i]:match('^%s*(.-)%s*$')
    if s ~= '' then pitches[#pitches + 1] = s end
    if count and #pitches >= count then break end
  end
  return pitches, description
end

-- Bridge Scala's convention (unison implicit, period last) to Continuum's
-- (step 1 = 1/1, period separate): prepend unison, split off final as period.
function M.scalaToTemper(pitchLines, name)
  if #pitchLines == 0 then return nil, 'no pitches' end
  for _, tok in ipairs(pitchLines) do
    if not M.scalaPitch(tok) then return nil, ('unparseable pitch: %q'):format(tok) end
  end
  -- Sort ascending so the widest interval is the period and cents stay
  -- monotonic regardless of paste order (a well-formed .scl is already sorted).
  local sorted = { table.unpack(pitchLines) }
  table.sort(sorted, function(a, b) return M.scalaPitch(a) < M.scalaPitch(b) end)
  local pitches = { '1/1' }
  for i = 1, #sorted - 1 do pitches[#pitches + 1] = sorted[i] end
  return M.derive{
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
function M.edoDegrees(spec, mode)
  local nums = {}
  for tok in spec:gmatch('%S+') do
    local n = tonumber(tok)
    if not n or n ~= math.floor(n) or n < 1 then return nil end
    nums[#nums + 1] = n
  end
  if #nums == 0 then return nil end
  if mode == 'relative' then
    local degs, acc = {}, 0
    for _, step in ipairs(nums) do acc = acc + step; degs[#degs + 1] = acc end
    return degs
  end
  table.sort(nums)
  local degs = {}
  for _, d in ipairs(nums) do if degs[#degs] ~= d then degs[#degs + 1] = d end end
  return degs
end

-- Inverse of edoDegrees: render a degree list back as a spec string in `mode`.
-- Lets a mode switch convert the in-flight pattern rather than reset it.
function M.degreesToSpec(degrees, mode)
  if mode == 'absolute' then return table.concat(degrees, ' ') end
  local steps, prev = {}, 0
  for _, d in ipairs(degrees) do steps[#steps + 1] = d - prev; prev = d end
  return table.concat(steps, ' ')
end

-- N-equal-divisions of `interval` subset to `degrees`; tokens are intensional
-- (d\D<equave>, suffix omitted for octave). Base 0 implicit; last degree = period.
function M.genEqual(degrees, interval)
  local D      = degrees[#degrees]
  local suffix = (interval and interval ~= '' and interval ~= '2/1') and ('<' .. interval .. '>') or ''
  local pitches = { '0\\' .. D .. suffix }
  for i = 1, #degrees - 1 do pitches[i + 1] = degrees[i] .. '\\' .. D .. suffix end
  return { pitches = pitches, periodPitch = D .. '\\' .. D .. suffix, periodAsStep = true }
end

-- Harmonic-series segment lo..hi: ratios m/lo rooted on the low harmonic, the
-- top (hi/lo) the period.
function M.genHarmonics(lo, hi)
  local pitches = {}
  for m = lo, hi - 1 do pitches[#pitches + 1] = m .. '/' .. lo end
  return { pitches = pitches, periodPitch = hi .. '/' .. lo, periodAsStep = true }
end

-- Subharmonic (utonal) segment lo..hi: ratios hi/m ascending, top the period.
function M.genSubharmonics(lo, hi)
  local pitches = {}
  for m = hi, lo + 1, -1 do pitches[#pitches + 1] = hi .. '/' .. m end
  return { pitches = pitches, periodPitch = hi .. '/' .. lo, periodAsStep = true }
end

-- Colon/space-separated extended ratio (e.g. '4:5:6:7') -> positive integers,
-- at least two. nil + message otherwise.
function M.parseChord(spec)
  local members = {}
  for tok in spec:gmatch('[^%s:]+') do
    local n = tonumber(tok)
    if not n or n ~= math.floor(n) or n < 1 then return nil, 'chord needs whole numbers' end
    members[#members + 1] = n
  end
  if #members < 2 then return nil, 'chord needs at least two notes' end
  return members
end

-- Enumerate a chord as a scale rooted on its first note. otonal: ci/c1.
-- inverted (utonal): ck/c(k+1-i). The last member is the period either way.
function M.genChord(members, invert)
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
    if depth > k then out[#out + 1] = { table.unpack(idx) }; return end
    for i = start, n do idx[depth] = i; rec(i + 1, depth + 1) end
  end
  rec(1, 1)
  return out
end

-- Combination product set: every k-subset's product, rooted on the smallest
-- product (so 1/1 is always present) and reduced into the equave; ascending.
function M.genCPS(factors, k, equave)
  equave = equave or '2/1'
  local ea, eb = equave:match('^(%d+)/(%d+)$')
  if not ea then ea, eb = equave:match('^(%d+)$'), '1' end
  ea, eb = tonumber(ea), tonumber(eb)
  local products = {}
  for _, subset in ipairs(combinations(#factors, k)) do
    local p = 1
    for _, i in ipairs(subset) do p = p * factors[i] end
    products[#products + 1] = p
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
  table.sort(tokens, function(x, y) return M.scalaPitch(x) < M.scalaPitch(y) end)
  return { pitches = tokens, periodPitch = equave, periodAsStep = true }
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
  for k = 0, n - 1 do pts[#pts + 1] = reduceCents(k * g, p) end
  table.sort(pts)
  local sizes = {}
  for i = 1, n do
    local step = ((i < n) and pts[i + 1] or p) - pts[i]
    local slot
    for _, s in ipairs(sizes) do if math.abs(s.cents - step) < 1e-6 then slot = s; break end end
    if slot then slot.count = slot.count + 1
    else sizes[#sizes + 1] = { cents = step, count = 1 } end
  end
  table.sort(sizes, function(a, b) return a.cents > b.cents end)
  return sizes
end

-- Rank-2 scale: stack the generator `up` above and `size-1-up` below 1/1,
-- reduce into period, sort. up = mode. Exact ratios if inputs rational, else cents.
function M.genRank2(generator, period, size, up)
  period = period or '2/1'
  local down = size - 1 - up
  local gn, gd = asRatio(generator)
  local pn, pd = asRatio(period)
  local g, p = M.scalaPitch(generator), M.scalaPitch(period)
  local entries = {}
  for k = -down, up do
    local num, den
    if gn and pn then num, den = stackRatio(gn, gd, pn, pd, k) end
    local cents = num and 1200 * math.log(num / den, 2) or reduceCents(k * g, p)
    local token = num and (num .. '/' .. den)
                  or ((cents < 1e-6) and '1/1' or string.format('%.4f', cents))
    entries[#entries + 1] = { cents = cents, token = token }
  end
  table.sort(entries, function(a, b) return a.cents < b.cents end)
  local pitches = {}
  for i, e in ipairs(entries) do pitches[i] = e.token end
  return { pitches = pitches, periodPitch = period, periodAsStep = true }
end

--contract: {isMos, large, small} for an n-note chain; large/small are L/s step counts when isMos
function M.mosInfo(generator, period, n)
  local spec = stepSpectrum(M.scalaPitch(generator), M.scalaPitch(period or '2/1'), n)
  if #spec ~= 2 then return { isMos = false } end
  return { isMos = true, large = spec[1].count, small = spec[2].count }
end

--contract: next MOS size (two step sizes) from fromN, stepping dir (+/-1); nil past the cap
function M.nextMosSize(generator, period, fromN, dir)
  local g, p = M.scalaPitch(generator), M.scalaPitch(period or '2/1')
  local n = fromN + dir
  while n >= 2 and n <= 400 do
    if #stepSpectrum(g, p, n) == 2 then return n end
    n = n + dir
  end
  return nil
end

----- Coordinate conversions

--contract: detune optional (defaults 0); snaps to nearest scale point including the period boundary (rounds up to step 1 of next octave)
--contract: returned octave is MIDI-relative (C-1 → -1)
function M.midiToStep(temper, midi, detune)
  detune = detune or 0
  local cents  = midi * 100 + detune
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

  return best, octave - 1
end

--contract: wraps out-of-range step by adjusting octave; clamps midi to 0..127 by folding overflow into detune (never silently drops)
function M.stepToMidi(temper, step, octave)
  local steps, n = temper.cents, #temper.cents
  while step < 1 do step = step + n; octave = octave - 1 end
  while step > n do step = step - n; octave = octave + 1 end

  local cents  = (octave + 1) * temper.period + steps[step]
  local midi   = math.floor(cents / 100 + 0.5)
  local detune = cents - midi * 100

  if midi < 0 then
    detune, midi = detune + 100 * midi, 0
  elseif midi > 127 then
    detune, midi = detune + 100 * (midi - 127), 127
  end

  return midi, detune
end

function M.snap(temper, midi, detune)
  return M.stepToMidi(temper, M.midiToStep(temper, midi, detune))
end

--contract: moves by n scale steps under temper, carrying the octave; n may be negative
function M.transposeStep(temper, midi, detune, n)
  local step, oct = M.midiToStep(temper, midi, detune)
  return M.stepToMidi(temper, step + n, oct)
end

----- Display

--contract: returns (note, octaveLabel); named ⇒ name, nameless ⇒ degree+'-'; octave+1 at octaveStep
function M.stepToParts(temper, step, octave)
  if step >= temper.octaveStep then octave = octave + 1 end
  local name = temper.stepNames and temper.stepNames[step]
  local note = (name and name ~= '') and name or (step .. '-')
  return note, octaveLabel(octave)
end

--contract: name ⇒ name+octave (C-4); blank/absent ⇒ degree-octave (7-4). Octave +1 at octaveStep.
function M.stepToText(temper, step, octave)
  local note, octaveStr = M.stepToParts(temper, step, octave)
  return note .. octaveStr
end

return M
