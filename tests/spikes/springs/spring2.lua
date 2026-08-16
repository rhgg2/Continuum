-- Spring-model spike, passage per invocation: lua spring2.lua <passage>
package.path = './?.lua;' .. package.path
local util     = require 'util'
local tuning   = require 'tuning'
local sonority = require 'sonority'

local edo12, HALF = tuning.presets['12EDO'], 50
local function gap(a, b) return (b - a + 600) % 1200 - 600 end
local function addCoords(coords, move)
  local sum = {}
  for p, e in pairs(coords) do sum[p] = e end
  for p, e in pairs(move) do local t = (sum[p] or 0) + e; sum[p] = t ~= 0 and t or nil end
  return sum
end
local function coordKey(coords)
  local ps = util.keys(coords); table.sort(ps)
  local parts = {}
  for _, p in ipairs(ps) do util.add(parts, p .. ':' .. coords[p]) end
  return table.concat(parts, ',')
end

----- passages
local function passage(chords)
  local notes = {}
  for _, chord in ipairs(chords) do
    for _, pitch in ipairs(chord.pitches) do
      util.add(notes, { ppq = chord.ppq, pitch = pitch, endppq = chord.ppq + (chord.len or 960) })
    end
  end
  return sonority.strands(notes, function(e) return tuning.stepClass(edo12, e.pitch, e.detune) end)
end
local function chord(p) return passage{ { ppq = 0, pitches = p } } end
local function prog(chords)
  local beats = {}
  for k, p in ipairs(chords) do beats[k] = { ppq = (k-1)*960, pitches = p } end
  return passage(beats)
end
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
  return sonority.strands(notes, function(e) return tuning.stepClass(edo12, e.pitch, e.detune) end)
end

----- per-sonority spelling beam
local function beamSpell(members, seat, moves, SPRING, W)
  local k = #members
  if k == 1 then return { { box = 0, devs = { 0 }, springs = {}, partial = false } } end
  local beam = { { asg = { [1] = { coords = {}, impl = seat[members[1]], dev = 0 } }, n = 1 } }
  for _ = 2, k do
    local nxt, seen = {}, {}
    for _, state in ipairs(beam) do
      for j = 1, k do
        if not state.asg[j] then
          for a = 1, k do
            if state.asg[a] then
              for _, move in ipairs(moves) do
                if move.height > 0 then
                  local impl = (state.asg[a].impl + move.cents) % 1200
                  local dev  = gap(seat[members[j]], impl)
                  if math.abs(dev) <= 100 then
                    local asg = {}
                    for m = 1, k do asg[m] = state.asg[m] end
                    asg[j] = { coords = addCoords(state.asg[a].coords, move.coords), impl = impl, dev = dev }
                    local skey = {}
                    for m = 1, k do skey[#skey+1] = asg[m] and (m .. '=' .. coordKey(asg[m].coords)) or '' end
                    local key = table.concat(skey, ';')
                    if not seen[key] then
                      seen[key] = true
                      local coordSet, devs = {}, {}
                      for m = 1, k do if asg[m] then
                        coordSet[#coordSet+1] = asg[m].coords; devs[#devs+1] = asg[m].dev
                      end end
                      local score = sonority.score(coordSet)
                      for x = 1, #devs do for y = x+1, #devs do
                        local r = (devs[y]-devs[x])/HALF; score = score + SPRING*r*r
                      end end
                      nxt[#nxt+1] = { asg = asg, n = state.n + 1, score = score }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    if #nxt == 0 then break end
    table.sort(nxt, function(a,b) return a.score < b.score end)
    beam = {}
    for i = 1, math.min(W, #nxt) do beam[i] = nxt[i] end
  end

  local list = {}
  if beam[1] and beam[1].n == k then
    for _, state in ipairs(beam) do
      local devs, springs = {}, {}
      for j = 1, k do devs[j] = state.asg[j].dev end
      for a = 1, k do for b = a+1, k do
        util.add(springs, { i = members[a], j = members[b], delta = devs[b] - devs[a] })
      end end
      local coordSet = {}
      for j = 1, k do coordSet[j] = state.asg[j].coords end
      util.add(list, { box = sonority.score(coordSet), devs = devs, springs = springs, partial = false })
    end
    return list
  end

  -- partial fallback: greedy components
  local asg, comp, placed = { [1] = { coords = {}, impl = seat[members[1]], dev = 0, c = 1 } }, 1, 1
  while placed < k do
    local grew = false
    for j = 1, k do
      if not asg[j] then
        for a = 1, k do
          if asg[a] then
            for _, move in ipairs(moves) do
              if move.height > 0 then
                local impl = (asg[a].impl + move.cents) % 1200
                local dev  = gap(seat[members[j]], impl)
                if math.abs(dev) <= 100 then
                  asg[j] = { coords = addCoords(asg[a].coords, move.coords), impl = impl, dev = dev, c = asg[a].c }
                  placed, grew = placed + 1, true
                  break
                end
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
          placed = placed + 1
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
  return { { box = box, devs = devs, springs = springs, partial = true } }
end

----- QP + iterate
local function qpSolve(nvars, springs, strength, SPRING, fixed, d0)
  local d = {}
  for i = 1, nvars do d[i] = d0 and d0[i] or 0 end
  if fixed then for i, v in pairs(fixed) do d[i] = v end end
  local touching = {}
  for i = 1, nvars do touching[i] = {} end
  for _, s in ipairs(springs) do
    util.add(touching[s.i], { other = s.j, delta = -s.delta })
    util.add(touching[s.j], { other = s.i, delta =  s.delta })
  end
  for _ = 1, 800 do
    local worst = 0
    for i = 1, nvars do
      if not (fixed and fixed[i] ~= nil) then
        local num, den = 0, strength
        for _, t in ipairs(touching[i]) do
          num = num + SPRING * (d[t.other] + t.delta); den = den + SPRING
        end
        local v = math.max(-HALF, math.min(HALF, num / den))
        if math.abs(v - d[i]) > worst then worst = math.abs(v - d[i]) end
        d[i] = v
      end
    end
    if worst < 1e-5 then break end
  end
  return d
end
local function springsFor(choice, lists)
  local all = {}
  for s, list in ipairs(lists) do
    for _, sp in ipairs(list[choice[s]].springs) do util.add(all, sp) end
  end
  return all
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
  for i = 1, #d do pull = pull + strength * (d[i]/HALF)^2 end
  return box + mist + pull, box, mist, pull
end
local function iterate(nvars, lists, choice, strength, SPRING)
  local d, loops = nil, 0
  for loop = 1, 40 do
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
  print(('=== %s (n=%d strength=%g spring=%g) ==='):format(name, n, strength, SPRING))
  local moves = tuning.moves{ pitches = movePitches }
  local seat = {}
  for i, s in ipairs(strands) do seat[i] = (s.notes[1].pitch % 12) * 100 end
  local walk = sonority.walk(strands, n)

  local t0 = os.clock()
  local lists, counts, anyPartial = {}, {}, false
  for s, son in ipairs(walk) do
    lists[s] = beamSpell(son.strands, seat, moves, SPRING, opts.beam or 24)
    counts[s] = #lists[s] .. (lists[s][1].partial and 'P' or '')
    anyPartial = anyPartial or lists[s][1].partial
  end
  local tEnum = os.clock() - t0

  local pairSeen, E = {}, 0
  for _, son in ipairs(walk) do
    local m = son.strands
    for a = 1, #m do for b = a+1, #m do
      local key = math.min(m[a],m[b])..'-'..math.max(m[a],m[b])
      if not pairSeen[key] then pairSeen[key] = true; E = E + 1 end
    end end
  end
  print(('V=%d sonorities=%d E=%d cycles=%d | spellings: %s%s'):format(
    #strands, #walk, E, E - #strands + 1, table.concat(counts, ' '),
    anyPartial and ' [partial]' or ''))

  local choice = {}
  for s in ipairs(lists) do choice[s] = 1 end
  t0 = os.clock()
  local d, _, loops = iterate(#strands, lists, choice, strength, SPRING)
  local tSolve = os.clock() - t0
  local cost, box, mist, pull = totalCost(d, choice, lists, strength, SPRING)
  print(('solve: cost=%.4f (box %.3f mist %.3f pull %.3f) loops=%d | enum %.0fms solve %.0fms')
    :format(cost, box, mist, pull, loops, tEnum*1000, tSolve*1000))

  math.randomseed(4242)
  t0 = os.clock()
  local bestR, distinct = math.huge, {}
  for _ = 1, opts.restarts or 10 do
    local rc = {}
    for s, list in ipairs(lists) do rc[s] = math.random(#list) end
    local rd = iterate(#strands, lists, rc, strength, SPRING)
    local c = totalCost(rd, rc, lists, strength, SPRING)
    distinct[('%.4f'):format(c)] = true
    if c < bestR then bestR = c end
  end
  local nd = 0; for _ in pairs(distinct) do nd = nd + 1 end
  print(('restarts: best=%.4f %s | %d minima | %.0fms'):format(bestR,
    bestR < cost - 1e-6 and 'BEATS greedy' or '(greedy already optimal among restarts)',
    nd, (os.clock()-t0)*1000))

  if opts.showStrands then
    for i, s in ipairs(strands) do
      print(('  strand %2d class %2s seat %6.1f d=%+7.2f realized %7.2f')
        :format(i, tostring(s.class), seat[i], d[i], (seat[i]+d[i]) % 1200))
    end
  end
  if opts.lattice then
    t0 = os.clock()
    local ok, placed = pcall(sonority.solveToMoves, strands, n, strength, edo12, moves)
    if ok and placed then
      local worst = 0
      for i = 1, #strands do
        local diff = math.abs(gap((placed.tunings[i].cents + placed.offset) % 1200, (seat[i]+d[i]) % 1200))
        if diff > worst then worst = diff end
      end
      print(('lattice: cost=%.4f offset=%+.2f %.0fms | max realized gap vs spring = %.2f cents')
        :format(placed.cost, placed.offset, (os.clock()-t0)*1000, worst))
    else
      print(('lattice: %s (%.0fms)'):format(ok and 'refused' or 'raised', (os.clock()-t0)*1000))
    end
  end
  if opts.screen then
    local fixed = { [1] = d[1] + 10 }
    local d2 = qpSolve(#strands, springsFor(choice, lists), strength, SPRING, fixed, d)
    local byOnset = {}
    local firstOnset = {}
    for s, son in ipairs(walk) do
      for _, i in ipairs(son.strands) do
        if not firstOnset[i] then firstOnset[i] = s end
      end
    end
    for i = 1, #strands do
      local o = firstOnset[i] or 0
      local delta = math.abs(d2[i] - d[i])
      if not byOnset[o] or delta > byOnset[o] then byOnset[o] = delta end
    end
    local parts = {}
    for o = 1, #walk do util.add(parts, ('%d:%.2f'):format(o, byOnset[o] or 0)) end
    print('screening (clamp strand1 +10, max |dd| by birth onset): ' .. table.concat(parts, ' '))
  end
  if opts.oracle then
    local product = 1
    for _, list in ipairs(lists) do product = product * #list end
    if product <= 200000 then
      local t0 = os.clock()
      local combo, bestC, bestD, bestCombo = {}, math.huge, nil, nil
      for s = 1, #lists do combo[s] = 1 end
      while true do
        local dd = qpSolve(#strands, springsFor(combo, lists), strength, SPRING)
        local c = totalCost(dd, combo, lists, strength, SPRING)
        if c < bestC then
          bestC, bestD = c, dd
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
        if os.clock() - t0 > 45 then print('oracle TIMED OUT'); break end
      end
      print(('oracle over %d combos: best=%.4f in %.1fs'):format(product, bestC, os.clock()-t0))
      if opts.lattice and bestD then
        local ok, placed = pcall(sonority.solveToMoves, strands, n, strength, edo12, moves)
        if ok and placed then
          local worst = 0
          for i = 1, #strands do
            local diff = math.abs(gap((placed.tunings[i].cents + placed.offset) % 1200, (seat[i]+bestD[i]) % 1200))
            if diff > worst then worst = diff end
          end
          print(('oracle vs lattice: max realized gap = %.2f cents'):format(worst))
        end
      end
    end
  end
  print('')
end

local M5  = { '1/1','3/2','5/4' }
local M7  = { '1/1','3/2','5/4','7/4' }
local M9  = { '1/1','3/2','5/4','7/4','9/8' }
local M11 = { '1/1','3/2','5/4','6/5','7/4','7/6','7/5','9/8','5/3','8/7','10/7' }

local pump = function() return prog{ {60,64,67}, {57,60,64}, {62,65,69}, {55,59,62}, {60,64,67} } end
local runs = {
  small = function()
    analyse('dominant seventh alone', chord{60,64,67,70}, 5, M7, 1, 8, { showStrands = true, lattice = true })
    analyse('C minor triad, no 6/5', chord{60,63,67}, 5, M5, 1, 8, { showStrands = true, lattice = true })
    analyse('diminished triad', chord{60,63,66}, 5, M7, 1, 8, { showStrands = true, lattice = true })
    analyse('rolled C minor', passage{ { ppq=0, pitches={60}, len=1440 },
      { ppq=480, pitches={63}, len=960 }, { ppq=960, pitches={67}, len=480 } }, 5, M5, 1, 8,
      { showStrands = true, lattice = true })
  end,
  progs = function()
    analyse('I-IV-V-I', prog{ {60,64,67}, {65,69,72}, {67,71,74}, {60,64,67} }, 5, M5, 1, 8, { lattice = true })
    analyse('ii-V-I of sevenths', prog{ {62,65,69,72}, {55,59,62,65}, {60,64,67,71} }, 5, M9, 1, 8, { lattice = true })
  end,
  pump = function()
    analyse('comma pump, stiff', pump(), 5, M5, 1, 40, { showStrands = true, lattice = true })
    analyse('comma pump, soft', pump(), 5, M5, 1, 2, { showStrands = true })
  end,
  ii64 = function()
    analyse('ii-V-I of sevenths, beam 24 + oracle', prog{ {62,65,69,72}, {55,59,62,65}, {60,64,67,71} }, 5, M9, 1, 8,
      { beam = 24, restarts = 40, lattice = true, oracle = true })
  end,
  take = function()
    local take = voiceLines({
      { 72,72,71,72,74,74,72,71,69,69,71,72,74,72,71,72 },
      { 67,65,65,67,67,65,64,62,62,64,65,67,65,65,62,64 },
      { 64,62,62,60,59,60,57,59,57,60,60,60,57,59,55,55 },
      { 55,53,55,52,50,53,52,50,53,52,48,48,50,50,47,48 },
      { 48,50,43,45,43,41,45,43,45,36,41,38,36,43,43,36 },
    }, 960)
    analyse('five-part take, 16 onsets', take, 5, M11, 1, 8, { restarts = 10, screen = true })
  end,
}
runs[arg[1]]()
