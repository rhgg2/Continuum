-- shared core for the spring spike (globals in SC)
local util     = require 'util'
local tuning   = require 'tuning'
local sonority = require 'sonority'
local edo12, HALF = tuning.presets['12EDO'], 50
SC = {}
function SC.gap(a, b) return (b - a + 600) % 1200 - 600 end
local gap = SC.gap
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
function SC.passage(chords)
  local notes = {}
  for _, chord in ipairs(chords) do
    for _, pitch in ipairs(chord.pitches) do
      util.add(notes, { ppq = chord.ppq, pitch = pitch, endppq = chord.ppq + (chord.len or 960) })
    end
  end
  return sonority.strands(notes, function(e) return tuning.stepClass(edo12, e) end)
end
function SC.chord(p) return SC.passage{ { ppq = 0, pitches = p } } end
function SC.prog(chords)
  local beats = {}
  for k, p in ipairs(chords) do beats[k] = { ppq = (k-1)*960, pitches = p } end
  return SC.passage(beats)
end
function SC.voiceLines(lines, beat)
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
  return sonority.strands(notes, function(e) return tuning.stepClass(edo12, e) end)
end
function SC.seatsOf(strands)
  local seat = {}
  for i, s in ipairs(strands) do seat[i] = (s.notes[1].pitch % 12) * 100 end
  return seat
end
function SC.beamSpell(members, seat, moves, SPRING, W)
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
      local devs, springs, coordSet = {}, {}, {}
      for j = 1, k do devs[j] = state.asg[j].dev; coordSet[j] = state.asg[j].coords end
      for a = 1, k do for b = a+1, k do
        util.add(springs, { i = members[a], j = members[b], delta = devs[b] - devs[a] })
      end end
      util.add(list, { box = sonority.score(coordSet), devs = devs, springs = springs, partial = false })
    end
    return list
  end
  -- greedy component fallback
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
function SC.qpSolve(nvars, springs, strength, SPRING, fixed, d0)
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
-- local QP: only `free` vars move, everything else in d is data
function SC.qpLocal(d, free, springs, strength, SPRING)
  local isFree = {}
  for _, i in ipairs(free) do isFree[i] = true end
  local touching = {}
  for _, i in ipairs(free) do touching[i] = {} end
  for _, s in ipairs(springs) do
    if isFree[s.i] then util.add(touching[s.i], { other = s.j, delta = -s.delta }) end
    if isFree[s.j] then util.add(touching[s.j], { other = s.i, delta =  s.delta }) end
  end
  for _ = 1, 400 do
    local worst = 0
    for _, i in ipairs(free) do
      local num, den = 0, strength
      for _, t in ipairs(touching[i]) do
        num = num + SPRING * ((d[t.other] or 0) + t.delta); den = den + SPRING
      end
      local v = math.max(-HALF, math.min(HALF, num / den))
      if math.abs(v - d[i]) > worst then worst = math.abs(v - d[i]) end
      d[i] = v
    end
    if worst < 1e-5 then break end
  end
  return d
end
function SC.springsFor(choice, lists)
  local all = {}
  for s, list in ipairs(lists) do
    for _, sp in ipairs(list[choice[s]].springs) do util.add(all, sp) end
  end
  return all
end
function SC.totalCost(d, choice, lists, strength, SPRING)
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
-- moves plus their pairwise compositions, deduped by coords; the box prices the reach
function SC.extendMoves(moves)
  local tuning = require 'tuning'
  local out, seen = {}, {}
  local function admit(cents, coords)
    local ps = {}
    for p, e in pairs(coords) do ps[#ps+1] = p .. ':' .. e end
    table.sort(ps)
    local key = table.concat(ps, ',')
    if seen[key] then return end
    seen[key] = true
    out[#out+1] = { cents = cents % 1200, coords = coords, height = tuning.height(coords) }
  end
  for _, m in ipairs(moves) do admit(m.cents, m.coords) end
  for _, a in ipairs(moves) do
    for _, b in ipairs(moves) do
      if a.height > 0 and b.height > 0 then
        local coords = {}
        for p, e in pairs(a.coords) do coords[p] = e end
        for p, e in pairs(b.coords) do
          local t = (coords[p] or 0) + e; coords[p] = t ~= 0 and t or nil
        end
        admit(a.cents + b.cents, coords)
      end
    end
  end
  return out
end
