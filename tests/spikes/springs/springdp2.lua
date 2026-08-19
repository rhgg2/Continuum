-- Onset DP v2: free variables at an onset are the strands still sounding there
-- (the waiting rule as warm QP variables), prefix cost recomputed exactly over
-- accumulated springs, winner settled by one full joint QP.
package.path = './?.lua;' .. package.path
local util     = require 'util'
local tuning   = require 'tuning'
local sonority = require 'sonority'
dofile('springcore.lua')
local edo12 = tuning.presets['12EDO']

local function dpSolve(strands, n, moves, strength, SPRING, opts)
  opts = opts or {}
  local K, beamW, QUANT = opts.K or 60, opts.beam or 24, opts.quant or 0.5
  local seat = SC.seatsOf(strands)
  local walk = sonority.walk(strands, n)
  local lists = {}
  for s, son in ipairs(walk) do lists[s] = SC.beamSpell(son.strands, seat, moves, SPRING, beamW) end

  local bornAt = {}
  for s, son in ipairs(walk) do
    for _, i in ipairs(son.strands) do if not bornAt[i] then bornAt[i] = s end end
  end
  local futureSees = {}
  for s = #walk, 1, -1 do
    local f = {}
    if s < #walk then
      for i in pairs(futureSees[s+1]) do f[i] = true end
      for _, i in ipairs(walk[s+1].strands) do f[i] = true end
    end
    futureSees[s] = f
  end
  local function soundingAt(strand, ppq)
    for _, note in ipairs(strand.notes) do
      if note.ppq <= ppq and ppq < note.endppq then return true end
    end
    return false
  end

  local states, qps = { { d = {}, choices = {}, boxSum = 0, springs = {} } }, 0
  for s = 1, #walk do
    local free = {}
    for _, i in ipairs(walk[s].strands) do
      if bornAt[i] == s or soundingAt(strands[i], walk[s].ppq) then free[#free+1] = i end
    end
    local nxt = {}
    for _, st in ipairs(states) do
      for c, sp in ipairs(lists[s]) do
        local d2 = {}
        for i, v in pairs(st.d) do d2[i] = v end
        for _, i in ipairs(walk[s].strands) do d2[i] = d2[i] or 0 end
        local all = {}
        for _, x in ipairs(st.springs) do all[#all+1] = x end
        for _, x in ipairs(sp.springs) do all[#all+1] = x end
        d2 = SC.qpLocal(d2, free, all, strength, SPRING)
        qps = qps + 1
        local boxSum = st.boxSum + sp.box
        local cost = boxSum
        for _, spring in ipairs(all) do
          local r = ((d2[spring.j] or 0) - (d2[spring.i] or 0) - spring.delta) / 50
          cost = cost + SPRING * r * r
        end
        for _, v in pairs(d2) do cost = cost + strength * (v/50)^2 end
        local choices = {}
        for k2, v in pairs(st.choices) do choices[k2] = v end
        choices[s] = c
        local keys = {}
        for i in pairs(futureSees[s]) do
          if d2[i] then keys[#keys+1] = i .. ':' .. math.floor(d2[i]/QUANT + 0.5) end
        end
        table.sort(keys)
        local key = table.concat(keys, ',')
        local cur = nxt[key]
        if not cur or cost < cur.cost then
          nxt[key] = { d = d2, choices = choices, boxSum = boxSum, springs = all, cost = cost }
        end
      end
    end
    states = {}
    for _, st in pairs(nxt) do states[#states+1] = st end
    table.sort(states, function(a,b) return a.cost < b.cost end)
    for i = #states, K + 1, -1 do states[i] = nil end
    if opts.trace then
      print(('  onset %2d: %4d states, best prefix %.4f'):format(s, #states, states[1].cost))
    end
  end

  local best = states[1]
  local d = SC.qpSolve(#strands, best.springs, strength, SPRING, nil, best.d)
  local cost = SC.totalCost(d, best.choices, lists, strength, SPRING)
  return { d = d, cost = cost, choices = best.choices, qps = qps, lists = lists,
           seat = seat, walk = walk, springs = best.springs }
end

local TAKE_NOTES = {
  {ppq=0,endppq=3809,pitch=48,detune=0},{ppq=0,endppq=3809,pitch=60,detune=0},
  {ppq=6144,endppq=9953,pitch=72,detune=0},
  {ppq=12288,endppq=16097,pitch=48,detune=0},{ppq=12288,endppq=16097,pitch=74,detune=0},
  {ppq=12288,endppq=16097,pitch=79,detune=0},{ppq=12288,endppq=18432,pitch=60,detune=0},
  {ppq=12288,endppq=22241,pitch=55,detune=0},{ppq=12288,endppq=24576,pitch=62,detune=0},
  {ppq=16097,endppq=18432,pitch=76,detune=0},{ppq=16097,endppq=18432,pitch=81,detune=0},
  {ppq=18432,endppq=22241,pitch=74,detune=0},{ppq=18432,endppq=22241,pitch=79,detune=0},
  {ppq=22241,endppq=24576,pitch=60,detune=0},{ppq=22241,endppq=24576,pitch=76,detune=0},
  {ppq=22241,endppq=24576,pitch=81,detune=0},{ppq=24576,endppq=26633,pitch=48,detune=0},
  {ppq=24576,endppq=28385,pitch=74,detune=0},{ppq=24576,endppq=28385,pitch=79,detune=0},
  {ppq=24576,endppq=30720,pitch=64,detune=0},{ppq=24576,endppq=40673,pitch=69,detune=0},
  {ppq=28385,endppq=30720,pitch=62,detune=0},{ppq=28385,endppq=30720,pitch=76,detune=0},
  {ppq=28385,endppq=30720,pitch=81,detune=0},{ppq=29705,endppq=30720,pitch=51,detune=0},
  {ppq=30720,endppq=34529,pitch=62,detune=0},{ppq=30720,endppq=34529,pitch=74,detune=0},
  {ppq=30720,endppq=34529,pitch=79,detune=0},{ppq=30720,endppq=36864,pitch=53,detune=0},
  {ppq=34529,endppq=36864,pitch=76,detune=0},{ppq=34529,endppq=36864,pitch=81,detune=0},
  {ppq=34529,endppq=38921,pitch=48,detune=0},{ppq=36864,endppq=40673,pitch=60,detune=0},
  {ppq=36864,endppq=40673,pitch=79,detune=0},{ppq=40673,endppq=41993,pitch=62,detune=0},
  {ppq=40673,endppq=43008,pitch=71,detune=0},{ppq=40673,endppq=43008,pitch=81,detune=0},
  {ppq=40673,endppq=46817,pitch=51,detune=0},{ppq=41993,endppq=43008,pitch=61,detune=0},
  {ppq=43008,endppq=46817,pitch=48,detune=0},{ppq=43008,endppq=46817,pitch=60,detune=0},
  {ppq=43008,endppq=49152,pitch=72,detune=0},{ppq=46817,endppq=48137,pitch=67,detune=0},
}
local TAKE_MOVES = { '16/15','9/8','6/5','5/4','4/3','3/2','8/5','5/3','16/9','15/8','2/1' }
local function takeStrands()
  return sonority.strands(TAKE_NOTES, function(e) return tuning.stepClass(edo12, e) end)
end

local runs = {}
function runs.rolled()
  local strands = SC.passage{ { ppq=0, pitches={60}, len=1440 },
    { ppq=480, pitches={63}, len=960 }, { ppq=960, pitches={67}, len=480 } }
  local r = dpSolve(strands, 5, SC.extendMoves(tuning.moves{ pitches = { '1/1','3/2','5/4' } }), 1, 8, {})
  print(('rolled minor: cost=%.4f; C %.2f Eb %.2f G %.2f  (want Eb ~309-315 via G)')
    :format(r.cost, (r.seat[1]+r.d[1]) % 1200, (r.seat[2]+r.d[2]) % 1200, (r.seat[3]+r.d[3]) % 1200))
end
function runs.ii()
  local strands = SC.prog{ {62,65,69,72}, {55,59,62,65}, {60,64,67,71} }
  local moves = SC.extendMoves(tuning.moves{ pitches = { '1/1','3/2','5/4','7/4','9/8' } })
  local t0 = os.clock()
  local r = dpSolve(strands, 5, moves, 1, 8, {})
  print(('ii-V-I: cost=%.4f %.0fms (oracle 18.3248)'):format(r.cost, (os.clock()-t0)*1000))
end
function runs.real()
  local strands = takeStrands()
  local moves = SC.extendMoves(tuning.moves{ pitches = TAKE_MOVES })
  print(('take: %d strands, %d moves (max height %.2f)'):format(#strands, #moves, moves[#moves].height))
  for _, v in ipairs{ { K=60 }, { K=20 }, { K=200 }, { K=60, beam=48 }, { K=60, quant=0.1 } } do
    local t0 = os.clock()
    local r = dpSolve(strands, 5, moves, 1, 8, v)
    print(('n=5 K=%3d beam=%2d quant=%.1f: cost=%.4f  %.2fs (%d QPs)')
      :format(v.K or 60, v.beam or 24, v.quant or 0.5, r.cost, os.clock()-t0, r.qps))
  end
  local t0 = os.clock()
  local r3 = dpSolve(strands, 3, moves, 1, 8, {})
  print(('n=3 K= 60: cost=%.4f  %.2fs'):format(r3.cost, os.clock()-t0))
end
function runs.screen()
  local strands = takeStrands()
  local moves = SC.extendMoves(tuning.moves{ pitches = TAKE_MOVES })
  local r = dpSolve(strands, 5, moves, 1, 8, {})
  local born = {}
  for s, son in ipairs(r.walk) do
    for _, i in ipairs(son.strands) do if not born[i] then born[i] = s end end
  end
  local d2 = SC.qpSolve(#strands, r.springs, 1, 8, { [1] = r.d[1] + 10 }, r.d)
  local byOnset = {}
  for i = 1, #strands do
    local delta = math.abs(d2[i] - r.d[i])
    if not byOnset[born[i]] or delta > byOnset[born[i]] then byOnset[born[i]] = delta end
  end
  for o = 1, #r.walk do print(('onset %2d: max |dd| = %6.3f'):format(o, byOnset[o] or 0)) end
end
function runs.lattice()
  local strands = takeStrands()
  local raw = tuning.moves{ pitches = TAKE_MOVES }
  local r = dpSolve(strands, 5, SC.extendMoves(raw), 1, 8, {})
  print(('DP: cost=%.4f'):format(r.cost))
  local t0 = os.clock()
  local ok, placed = pcall(sonority.solveToMoves, strands, 5, 1, edo12, raw)
  local t = os.clock() - t0
  if ok and placed then
    local worst = 0
    for i = 1, #strands do
      local diff = math.abs(SC.gap((placed.tunings[i].cents + placed.offset) % 1200,
                                   (r.seat[i] + r.d[i]) % 1200))
      if diff > worst then worst = diff end
    end
    print(('lattice: cost=%.4f offset=%+.2f in %.1fs | max realized gap vs DP = %.2f cents')
      :format(placed.cost, placed.offset, t, worst))
  else
    print(('lattice: %s in %.1fs'):format(ok and 'refused' or ('raised: '..tostring(placed)), t))
  end
end
runs[arg[1]]()
