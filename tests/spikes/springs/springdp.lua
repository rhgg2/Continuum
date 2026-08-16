-- Onset DP: states carry chosen spellings so far; a state's key is the rounded
-- cents of the strands the future can still see, so pasts the future cannot
-- tell apart merge. Extension QP frees only the strands born at the onset;
-- the winner is settled with one full joint QP at the end.
package.path = './?.lua;' .. package.path
local util     = require 'util'
local tuning   = require 'tuning'
local sonority = require 'sonority'
dofile('springcore.lua')  -- SC.* : passages, beamSpell, qpSolve, springsFor, totalCost

local edo12 = tuning.presets['12EDO']

local function dpSolve(strands, n, moves, strength, SPRING, opts)
  opts = opts or {}
  local K, beamW, QUANT = opts.K or 60, opts.beam or 24, opts.quant or 0.5
  local seat = SC.seatsOf(strands)
  local walk = sonority.walk(strands, n)

  local lists = {}
  for s, son in ipairs(walk) do
    lists[s] = SC.beamSpell(son.strands, seat, moves, SPRING, beamW)
  end

  -- who is born where; which strands each suffix can still see
  local bornAt, seen = {}, {}
  for s, son in ipairs(walk) do
    for _, i in ipairs(son.strands) do
      if not seen[i] then seen[i], bornAt[i] = true, s end
    end
  end
  local futureSees = {}   -- futureSees[s] = strands appearing in any sonority > s
  for s = #walk, 1, -1 do
    local f = {}
    if s < #walk then
      for i in pairs(futureSees[s+1]) do f[i] = true end
      for _, i in ipairs(walk[s+1].strands) do f[i] = true end
    end
    futureSees[s] = f
  end

  local states = { { d = {}, choices = {}, cost = 0 } }
  local qps = 0
  for s = 1, #walk do
    local nxt = {}
    for _, st in ipairs(states) do
      for c, sp in ipairs(lists[s]) do
        -- QP freeing only the strands born here, everything earlier fixed
        local fixed = {}
        for i, v in pairs(st.d) do if bornAt[i] < s then fixed[i] = v end end
        local d2 = {}
        for i, v in pairs(st.d) do d2[i] = v end
        for _, i in ipairs(walk[s].strands) do d2[i] = d2[i] or 0 end
        local free = {}
        for _, i in ipairs(walk[s].strands) do if bornAt[i] == s then free[#free+1] = i end end
        d2 = SC.qpLocal(d2, free, sp.springs, strength, SPRING)
        qps = qps + 1
        -- prefix cost: previous + this sonority's box, springs, new pull
        local cost = st.cost + sp.box
        for _, spring in ipairs(sp.springs) do
          local r = (d2[spring.j] - d2[spring.i] - spring.delta) / 50
          cost = cost + SPRING * r * r
        end
        for _, i in ipairs(free) do cost = cost + strength * (d2[i]/50)^2 end
        local choices = {}
        for k, v in pairs(st.choices) do choices[k] = v end
        choices[s] = c
        -- merge key: rounded d of strands the future can see
        local keys = {}
        for i in pairs(futureSees[s]) do
          if d2[i] then keys[#keys+1] = i .. ':' .. math.floor(d2[i]/QUANT + 0.5) end
        end
        table.sort(keys)
        local key = table.concat(keys, ',')
        local cur = nxt[key]
        if not cur or cost < cur.cost then
          nxt[key] = { d = d2, choices = choices, cost = cost }
        end
      end
    end
    states = {}
    for _, st in pairs(nxt) do states[#states+1] = st end
    table.sort(states, function(a,b) return a.cost < b.cost end)
    for i = #states, K + 1, -1 do states[i] = nil end
    if opts.trace then
      print(('  onset %2d: %4d states kept (cap %d), best prefix %.4f'):format(s, #states, K, states[1].cost))
    end
  end

  -- settle the winner: full joint QP over its chosen springs
  local best = states[1]
  local all = SC.springsFor(best.choices, lists)
  local d = SC.qpSolve(#strands, all, strength, SPRING, nil, best.d)
  local cost = SC.totalCost(d, best.choices, lists, strength, SPRING)
  return { d = d, cost = cost, choices = best.choices, qps = qps, lists = lists, seat = seat }
end

----- runs
local M9  = { '1/1','3/2','5/4','7/4','9/8' }
local M11 = { '1/1','3/2','5/4','6/5','7/4','7/6','7/5','9/8','5/3','8/7','10/7' }

local runs = {}
function runs.ii()
  local strands = SC.prog{ {62,65,69,72}, {55,59,62,65}, {60,64,67,71} }
  local t0 = os.clock()
  local r = dpSolve(strands, 5, tuning.moves{ pitches = M9 }, 1, 8, { trace = true })
  print(('DP: cost=%.4f, %d QPs, %.1fms  (oracle best was 18.3248, lattice 18.3322)')
    :format(r.cost, r.qps, (os.clock()-t0)*1000))
  local ok, placed = pcall(sonority.solveToMoves, strands, 5, 1, edo12, tuning.moves{ pitches = M9 })
  if ok and placed then
    local worst = 0
    for i = 1, #strands do
      local diff = math.abs(SC.gap((placed.tunings[i].cents + placed.offset) % 1200,
                                   (r.seat[i] + r.d[i]) % 1200))
      if diff > worst then worst = diff end
    end
    print(('DP vs lattice realized gap: %.2f cents'):format(worst))
  end
end
function runs.pump()
  local strands = SC.prog{ {60,64,67}, {57,60,64}, {62,65,69}, {55,59,62}, {60,64,67} }
  local t0 = os.clock()
  local r = dpSolve(strands, 5, tuning.moves{ pitches = { '1/1','3/2','5/4' } }, 1, 40, {})
  print(('DP pump stiff: cost=%.4f, %d QPs, %.0fms; opening C %.2f closing C %.2f')
    :format(r.cost, r.qps, (os.clock()-t0)*1000,
      (r.seat[1]+r.d[1]) % 1200, (r.seat[3]+r.d[3]) % 1200))
end
function runs.take()
  local strands = SC.voiceLines({
    { 72,72,71,72,74,74,72,71,69,69,71,72,74,72,71,72 },
    { 67,65,65,67,67,65,64,62,62,64,65,67,65,65,62,64 },
    { 64,62,62,60,59,60,57,59,57,60,60,60,57,59,55,55 },
    { 55,53,55,52,50,53,52,50,53,52,48,48,50,50,47,48 },
    { 48,50,43,45,43,41,45,43,45,36,41,38,36,43,43,36 },
  }, 960)
  local t0 = os.clock()
  local r = dpSolve(strands, 5, tuning.moves{ pitches = M11 }, 1, 8, { trace = true, K = 60 })
  print(('DP take: cost=%.4f, %d QPs, %.1fs'):format(r.cost, r.qps, os.clock()-t0))
end
function runs.takes()
  local strands = SC.voiceLines({
    { 72,72,71,72,74,74,72,71,69,69,71,72,74,72,71,72 },
    { 67,65,65,67,67,65,64,62,62,64,65,67,65,65,62,64 },
    { 64,62,62,60,59,60,57,59,57,60,60,60,57,59,55,55 },
    { 55,53,55,52,50,53,52,50,53,52,48,48,50,50,47,48 },
    { 48,50,43,45,43,41,45,43,45,36,41,38,36,43,43,36 },
  }, 960)
  local moves = tuning.moves{ pitches = M11 }
  for _, v in ipairs{
    { K = 20,  beam = 24, quant = 0.5 },
    { K = 60,  beam = 24, quant = 0.5 },
    { K = 200, beam = 24, quant = 0.5 },
    { K = 60,  beam = 24, quant = 0.1 },
    { K = 60,  beam = 48, quant = 0.5 },
  } do
    local t0 = os.clock()
    local r = dpSolve(strands, 5, moves, 1, 8, v)
    print(('K=%3d beam=%2d quant=%.1f: cost=%.4f  %.2fs  (%d QPs)')
      :format(v.K, v.beam, v.quant, r.cost, os.clock()-t0, r.qps))
  end
end
function runs.screen()
  local strands = SC.voiceLines({
    { 72,72,71,72,74,74,72,71,69,69,71,72,74,72,71,72 },
    { 67,65,65,67,67,65,64,62,62,64,65,67,65,65,62,64 },
    { 64,62,62,60,59,60,57,59,57,60,60,60,57,59,55,55 },
    { 55,53,55,52,50,53,52,50,53,52,48,48,50,50,47,48 },
    { 48,50,43,45,43,41,45,43,45,36,41,38,36,43,43,36 },
  }, 960)
  local moves = tuning.moves{ pitches = M11 }
  local r = dpSolve(strands, 5, moves, 1, 8, {})
  local walk = sonority.walk(strands, 5)
  local born = {}
  for s, son in ipairs(walk) do
    for _, i in ipairs(son.strands) do if not born[i] then born[i] = s end end
  end
  local springs = SC.springsFor(r.choices, r.lists)
  local d2 = SC.qpSolve(#strands, springs, 1, 8, { [1] = r.d[1] + 10 }, r.d)
  local byOnset = {}
  for i = 1, #strands do
    local delta = math.abs(d2[i] - r.d[i])
    local o = born[i]
    if not byOnset[o] or delta > byOnset[o] then byOnset[o] = delta end
  end
  for o = 1, #walk do
    print(('onset %2d: max |dd| = %6.3f cents'):format(o, byOnset[o] or 0))
  end
end
function runs.rolled()
  local strands = SC.passage{ { ppq=0, pitches={60}, len=1440 },
    { ppq=480, pitches={63}, len=960 }, { ppq=960, pitches={67}, len=480 } }
  local moves = tuning.moves{ pitches = { '1/1','3/2','5/4' } }
  local r = dpSolve(strands, 5, moves, 1, 8, {})
  print(('rolled minor via DP: cost=%.4f; C %.2f Eb %.2f G %.2f')
    :format(r.cost, (r.seat[1]+r.d[1]) % 1200, (r.seat[2]+r.d[2]) % 1200, (r.seat[3]+r.d[3]) % 1200))
end
runs[arg[1]]()
