-- Spring-model spike: state in cents, pure intervals as soft targets.
-- Questions: (A) per-sonority spelling counts stay small? (B) does iterated
-- local search match exhaustive? (C) wall time vs the lattice search?
-- (D) screening length? (E) comma behaviour under stiff vs soft springs?

package.path = './?.lua;' .. package.path
local util     = require 'util'
local tuning   = require 'tuning'
local sonority = require 'sonority'

local edo12  = tuning.presets['12EDO']
local HALF   = 50          -- 12-EDO half-window either side
local MAXDEV = 100 + 1e-9  -- enumeration bound on a spelled note's offset from its seat

local function gap(a, b) return (b - a + 600) % 1200 - 600 end  -- signed reduced b-a

----- passage builders (as the specs build them)

local function passage(chords)
  local notes = {}
  for _, chord in ipairs(chords) do
    for _, pitch in ipairs(chord.pitches) do
      util.add(notes, { ppq = chord.ppq, pitch = pitch,
                        endppq = chord.ppq + (chord.len or 960) })
    end
  end
  return sonority.strands(notes, function(e)
    return tuning.stepClass(edo12, e)
  end)
end

local function chord(pitches) return passage{ { ppq = 0, pitches = pitches } } end

local function prog(chords)
  local beats = {}
  for k, pitches in ipairs(chords) do beats[k] = { ppq = (k-1)*960, pitches = pitches } end
  return passage(beats)
end

-- voice lines -> notes, consecutive equal pitches merging into one held note
local function voiceLines(lines, beat)
  local notes = {}
  for _, line in ipairs(lines) do
    local i = 1
    while i <= #line do
      local j = i
      while j < #line and line[j+1] == line[i] do j = j + 1 end
      util.add(notes, { ppq = (i-1)*beat, pitch = line[i], endppq = j*beat })
      i = j + 1
    end
  end
  return sonority.strands(notes, function(e)
    return tuning.stepClass(edo12, e)
  end)
end

----- coords helpers

local function addCoords(coords, move)
  local sum = {}
  for p, e in pairs(coords) do sum[p] = e end
  for p, e in pairs(move) do
    local t = (sum[p] or 0) + e
    sum[p] = t ~= 0 and t or nil
  end
  return sum
end

local function coordKey(coords)
  local ps = util.keys(coords); table.sort(ps)
  local parts = {}
  for _, p in ipairs(ps) do util.add(parts, p .. ':' .. coords[p]) end
  return table.concat(parts, ',')
end

----- per-sonority spelling enumeration
-- A spelling assigns each member coords relative to the first, giving each a
-- dev: where the spelled pitch sits relative to the written seat, in cents.
-- Springs are dev differences; the box is scored off the coords as now.

local function seatsOf(strands)
  local seat = {}
  for i, s in ipairs(strands) do seat[i] = (s.notes[1].pitch % 12) * 100 end
  return seat
end

local function spellings(members, seat, moves, cap)
  cap = cap or 3000
  local k = #members
  local results, seen, visited, capped = {}, {}, {}, false

  local function record(asg)
    local keys = {}
    for j = 1, k do keys[j] = coordKey(asg[j].coords) end
    local key = table.concat(keys, '|')
    if seen[key] then return end
    seen[key] = true
    local coordSet, devs = {}, {}
    for j = 1, k do coordSet[j] = asg[j].coords; devs[j] = asg[j].dev end
    local springs = {}
    for a = 1, k do for b = a+1, k do
      util.add(springs, { i = members[a], j = members[b], delta = devs[b] - devs[a] })
    end end
    util.add(results, { box = sonority.score(coordSet), devs = devs,
                        springs = springs, partial = false })
  end

  local function grow(asg, mask, count)
    if #results >= cap then capped = true; return end
    if count == k then record(asg); return end
    local skey = { mask }
    for j = 1, k do if asg[j] then util.add(skey, j .. '=' .. coordKey(asg[j].coords)) end end
    local state = table.concat(skey, ';')
    if visited[state] then return end
    visited[state] = true
    for j = 1, k do
      if not asg[j] then
        for a = 1, k do
          if asg[a] then
            for _, move in ipairs(moves) do
              local impl = (asg[a].impl + move.cents) % 1200
              local dev  = gap(seat[members[j]], impl)
              if math.abs(dev) <= MAXDEV then
                asg[j] = { coords = addCoords(asg[a].coords, move.coords),
                           impl = impl, dev = dev }
                grow(asg, mask | (1 << j), count + 1)
                asg[j] = nil
              end
            end
          end
        end
      end
    end
  end

  local root = seat[members[1]]
  grow({ [1] = { coords = {}, impl = root, dev = 0 } }, 1 | (1 << 1), 1)

  if #results == 0 then
    -- partial fallback: greedy components, springs only inside a component
    local asg, comp = { [1] = { coords = {}, impl = root, dev = 0, c = 1 } }, 1
    local placedCount = 1
    while placedCount < k do
      local grew = false
      for j = 1, k do
        if not asg[j] then
          for a = 1, k do
            if asg[a] then
              for _, move in ipairs(moves) do
                local impl = (asg[a].impl + move.cents) % 1200
                local dev  = gap(seat[members[j]], impl)
                if math.abs(dev) <= MAXDEV then
                  asg[j] = { coords = addCoords(asg[a].coords, move.coords),
                             impl = impl, dev = dev, c = asg[a].c }
                  placedCount, grew = placedCount + 1, true
                  break
                end
              end
            end
            if asg[j] then break end
          end
        end
      end
      if not grew then
        for j = 1, k do
          if not asg[j] then
            comp = comp + 1
            asg[j] = { coords = {}, impl = seat[members[j]], dev = 0, c = comp }
            placedCount = placedCount + 1
            break
          end
        end
      end
    end
    local box, springs, devs = 0, {}, {}
    for c = 1, comp do
      local coordSet = {}
      for j = 1, k do if asg[j].c == c then util.add(coordSet, asg[j].coords) end end
      if #coordSet > 1 then box = box + sonority.score(coordSet) end
    end
    for a = 1, k do for b = a+1, k do
      if asg[a].c == asg[b].c then
        util.add(springs, { i = members[a], j = members[b], delta = asg[b].dev - asg[a].dev })
      end
    end end
    for j = 1, k do devs[j] = asg[j].dev end
    util.add(results, { box = box, devs = devs, springs = springs, partial = true })
  end

  return results, capped
end

----- the QP: projected Gauss-Seidel over per-strand displacements

local function qpSolve(nvars, springs, strength, SPRING, fixed, d0)
  local d = {}
  for i = 1, nvars do d[i] = d0 and d0[i] or 0 end
  if fixed then for i, v in pairs(fixed) do d[i] = v end end
  local touching = {}
  for i = 1, nvars do touching[i] = {} end
  for _, s in ipairs(springs) do
    util.add(touching[s.i], { other = s.j, delta = -s.delta })  -- d_i target: d_j - delta
    util.add(touching[s.j], { other = s.i, delta =  s.delta })  -- d_j target: d_i + delta
  end
  for sweep = 1, 800 do
    local worst = 0
    for i = 1, nvars do
      if not (fixed and fixed[i]) then
        local num, den = 0, strength
        for _, t in ipairs(touching[i]) do
          num = num + SPRING * (d[t.other] + t.delta)
          den = den + SPRING
        end
        local v = math.max(-HALF, math.min(HALF, num / den))
        local delta = math.abs(v - d[i])
        if delta > worst then worst = delta end
        d[i] = v
      end
    end
    if worst < 1e-6 then break end
  end
  return d
end

local function totalCost(d, choice, lists, strength, SPRING)
  local box, mist, pull = 0, 0, 0
  for s, list in ipairs(lists) do
    local sp = list[choice[s]]
    box = box + sp.box
    for _, spring in ipairs(sp.springs) do
      local r = (d[spring.j] - d[spring.i] - spring.delta) / HALF
      mist = mist + SPRING * r * r
    end
  end
  for i = 1, #d do pull = pull + strength * (d[i]/HALF) * (d[i]/HALF) end
  return box + mist + pull, box, mist, pull
end

local function springsFor(choice, lists)
  local all = {}
  for s, list in ipairs(lists) do
    for _, spring in ipairs(list[choice[s]].springs) do util.add(all, spring) end
  end
  return all
end

-- iterate: QP <-> per-sonority re-choice until fixed point
local function iterate(nvars, lists, choice, strength, SPRING, maxloops)
  local d, loops = nil, 0
  for loop = 1, maxloops or 30 do
    loops = loop
    d = qpSolve(nvars, springsFor(choice, lists), strength, SPRING, nil, d)
    local changed = false
    for s, list in ipairs(lists) do
      local bestCost, best = math.huge, choice[s]
      for c, sp in ipairs(list) do
        local cost = sp.box
        for _, spring in ipairs(sp.springs) do
          local r = (d[spring.j] - d[spring.i] - spring.delta) / HALF
          cost = cost + SPRING * r * r
        end
        if cost < bestCost - 1e-12 then bestCost, best = cost, c end
      end
      if best ~= choice[s] then choice[s], changed = best, true end
    end
    if not changed then break end
  end
  d = qpSolve(nvars, springsFor(choice, lists), strength, SPRING, nil, d)
  return d, choice, loops
end

----- driver

local function analyse(name, strands, n, movePitches, strength, SPRING, opts)
  opts = opts or {}
  print(('\n=== %s  (n=%d, strength=%g, spring=%g) ==='):format(name, n, strength, SPRING))
  local moves = tuning.moves{ pitches = movePitches }
  local seat  = seatsOf(strands)
  local walk  = sonority.walk(strands, n)
  local t0    = os.clock()

  -- spelling lists per sonority
  local lists, counts, anyCap, anyPartial = {}, {}, false, false
  for s, son in ipairs(walk) do
    local list, capped = spellings(son.strands, seat, moves)
    lists[s] = list
    counts[s] = #list .. (list[1] and list[1].partial and 'P' or '')
    anyCap = anyCap or capped
    anyPartial = anyPartial or (list[1] and list[1].partial)
  end
  local tEnum = os.clock() - t0

  -- graph numbers
  local pairSeen, E = {}, 0
  for _, son in ipairs(walk) do
    local m = son.strands
    for a = 1, #m do for b = a+1, #m do
      local key = math.min(m[a],m[b]) .. '-' .. math.max(m[a],m[b])
      if not pairSeen[key] then pairSeen[key] = true; E = E + 1 end
    end end
  end
  print(('strands V=%d  sonorities=%d  neighbour pairs E=%d  cycle dim (E-V+1)=%d')
    :format(#strands, #walk, E, E - #strands + 1))
  print('spellings per sonority: ' .. table.concat(counts, ' ')
        .. (anyCap and '  [CAPPED]' or '') .. (anyPartial and '  [partial fallback used]' or ''))

  -- greedy start: min box + spring residual at d=0
  local choice = {}
  for s, list in ipairs(lists) do
    local bestCost, best = math.huge, 1
    for c, sp in ipairs(list) do
      local cost = sp.box
      for _, spring in ipairs(sp.springs) do
        cost = cost + SPRING * (spring.delta/HALF) * (spring.delta/HALF)
      end
      if cost < bestCost then bestCost, best = cost, c end
    end
    choice[s] = best
  end

  t0 = os.clock()
  local d, _, loops = iterate(#strands, lists, choice, strength, SPRING)
  local tSolve = os.clock() - t0
  local cost, box, mist, pull = totalCost(d, choice, lists, strength, SPRING)
  print(('iterated local: cost=%.4f (box %.4f + mistune %.4f + pull %.4f)  loops=%d  enum %.0fms  solve %.0fms')
    :format(cost, box, mist, pull, loops, tEnum*1000, tSolve*1000))

  -- exhaustive oracle where affordable, else random restarts
  local product = 1
  for _, list in ipairs(lists) do product = product * #list end
  if product <= (opts.exhaustCap or 20000) then
    t0 = os.clock()
    local combo, bestCost, bestCombo = {}, math.huge, nil
    for s = 1, #lists do combo[s] = 1 end
    while true do
      local dd = qpSolve(#strands, springsFor(combo, lists), strength, SPRING)
      local c = totalCost(dd, combo, lists, strength, SPRING)
      if c < bestCost then
        bestCost = c
        bestCombo = {}
        for s = 1, #lists do bestCombo[s] = combo[s] end
      end
      local s = 1
      while s <= #lists do
        combo[s] = combo[s] + 1
        if combo[s] <= #lists[s] then break end
        combo[s] = 1; s = s + 1
      end
      if s > #lists then break end
    end
    print(('exhaustive over %d combos: best=%.4f  (%s)  %.0fms'):format(
      product, bestCost,
      math.abs(bestCost - cost) < 1e-6 and 'MATCHES iterated local'
        or ('iterated local off by ' .. string.format('%.4f', cost - bestCost)),
      (os.clock()-t0)*1000))
  else
    t0 = os.clock()
    math.randomseed(42)
    local restarts, distinct, bestR = opts.restarts or 30, {}, math.huge
    for r = 1, restarts do
      local rc = {}
      for s, list in ipairs(lists) do rc[s] = math.random(#list) end
      local rd = iterate(#strands, lists, rc, strength, SPRING)
      local c = totalCost(rd, rc, lists, strength, SPRING)
      distinct[string.format('%.4f', c)] = true
      if c < bestR then bestR = c end
    end
    local nd = 0; for _ in pairs(distinct) do nd = nd + 1 end
    print(('%d random restarts: best=%.4f (%s), %d distinct local minima, %.0fms'):format(
      restarts, bestR,
      bestR < cost - 1e-6 and ('BEATS greedy start by ' .. string.format('%.4f', cost - bestR))
        or 'greedy start already there', nd, (os.clock()-t0)*1000))
  end

  if opts.showStrands then
    for i, s in ipairs(strands) do
      print(('  strand %2d class %2s seat %6.1f  d=%+7.2f  realized %7.2f')
        :format(i, tostring(s.class), seat[i], d[i], (seat[i] + d[i]) % 1200))
    end
  end

  -- lattice comparison
  if opts.lattice ~= false then
    t0 = os.clock()
    local ok, placed = pcall(sonority.solveToMoves, strands, n, strength, edo12, moves)
    local tL = os.clock() - t0
    if ok and placed then
      local worst = 0
      for i = 1, #strands do
        local lat = (placed.tunings[i].cents + placed.offset) % 1200
        local spr = (seat[i] + d[i]) % 1200
        local diff = math.abs(gap(lat, spr))
        if diff > worst then worst = diff end
      end
      print(('lattice: cost=%.4f offset=%+.2f in %.0fms; max |lattice-spring| realized gap = %.2f cents')
        :format(placed.cost, placed.offset, tL*1000, worst))
    else
      print(('lattice: %s in %.0fms'):format(
        ok and 'REFUSED (no placement at any offset)' or ('RAISED: ' .. tostring(placed)), tL*1000))
    end
  end

  return d, choice, lists, seat
end

----- passages

local pump = prog{ {60,64,67}, {57,60,64}, {62,65,69}, {55,59,62}, {60,64,67} }

local rolled = passage{ { ppq = 0,   pitches = { 60 }, len = 1440 },
                        { ppq = 480, pitches = { 63 }, len = 960 },
                        { ppq = 960, pitches = { 67 }, len = 480 } }

local take = voiceLines({
  { 72,72,71,72,74,74,72,71,69,69,71,72,74,72,71,72 },
  { 67,65,65,67,67,65,64,62,62,64,65,67,65,65,62,64 },
  { 64,62,62,60,59,60,57,59,57,60,60,60,57,59,55,55 },
  { 55,53,55,52,50,53,52,50,53,52,48,48,50,50,47,48 },
  { 48,50,43,45,43,41,45,43,45,36,41,38,36,43,43,36 },
}, 960)

local M5   = { '1/1','3/2','5/4' }
local M7   = { '1/1','3/2','5/4','7/4' }
local M9   = { '1/1','3/2','5/4','7/4','9/8' }
local M11  = { '1/1','3/2','5/4','6/5','7/4','7/6','7/5','9/8','5/3','8/7','10/7' }

analyse('dominant seventh alone (expect 4:5:6:7)', chord{60,64,67,70}, 5, M7, 1, 8,
        { showStrands = true })
analyse('C minor triad, no 6/5 in set (expect Eb via G at ~315.6)', chord{60,63,67}, 5, M5, 1, 8,
        { showStrands = true })
analyse('diminished triad (lattice needs offset +18.8)', chord{60,63,66}, 5, M7, 1, 8,
        { showStrands = true })
analyse('rolled C minor (waiting case)', rolled, 5, M5, 1, 8, { showStrands = true })
analyse('I-IV-V-I', prog{ {60,64,67}, {65,69,72}, {67,71,74}, {60,64,67} }, 5, M5, 1, 8)
analyse('ii-V-I of sevenths', prog{ {62,65,69,72}, {55,59,62,65}, {60,64,67,71} }, 5, M9, 1, 8)
analyse('comma pump, stiff springs (expect drift ~ -21.5)', pump, 5, M5, 1, 40,
        { showStrands = true })
analyse('comma pump, soft springs (expect distribution)', pump, 5, M5, 1, 2)
analyse('five-part take, 16 sonorities', take, 5, M11, 1, 8, { restarts = 20 })
