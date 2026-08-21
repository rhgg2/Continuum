-- Times sonority.solveToMoves over the take, at the dials the retune modal opens on, and
-- prints the tuning's checksum so a change meant to cost less can be held to costing the
-- same. Run from the repo root: lua tests/spikes/springs/take_bench.lua
--
-- 1.8s at the time of writing, where the beam's reach gate held it to 0.57 and charging the
-- whole passage's pull at every extension cost 4.08 (docs/sonority.md § The solve).
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local take     = require('take')

local at    = os.clock()
local cents = sonority.solveToMoves(take.strands, 5, 1, take.notation, take.target, 8, 1)
local took  = os.clock() - at

if not cents then
  print(string.format('%.2fs  refused — the target states no move', took))
  return
end

local seat = sonority.seats(take.strands, take.notation)
local total, worst, checksum = 0, 0, 0
for index = 1, #take.strands do
  local moved = cents[index] - seat[index]
  total, worst = total + math.abs(moved), math.max(worst, math.abs(moved))
  checksum = checksum + cents[index]
end

print(string.format('%.2fs  %d notes, %d strands  mean %.4f  worst %.4f  checksum %.6f',
                    took, #take.notes, #take.strands, total / #take.strands, worst, checksum))
