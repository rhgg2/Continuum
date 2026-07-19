-- "Glasswork-dense" -- the producer-dense single-channel variant of glasswork,
-- built for interval-dirt Phase 5 commit 5 (the fx-gate measurement).
--
-- glasswork spreads its generators over 16 channels, so a one-note edit dirties
-- one lightly-loaded channel and the flush is write-bound -- the phase-5 fx gate
-- has almost nothing to skip (~3ms of re-derive). This variant piles the same
-- continuous chains onto ONE channel (chan 1) as six lanes of back-to-back
-- one-bar hosts across all 32 bars, so rebuild(true) folds every producer -- the
-- forced-full ceiling -- while a one-note edit seeds a single window and the gate
-- keeps the rest. Four lanes are continuous (the expensive fold the gate narrows:
-- pb x2, cc1, cc10); two are note chains. See design/interval-dirt.md § phase 5.
--
-- Same caller contract as glasswork: set temper='53EDO', swing 'c58' global, and
-- length = LENGTH BEFORE build(). Bridge-driven; not blob-reproducible.

local gw = require('fixtures.glasswork')
local e53, BAR, LENGTH, classic58 = gw.e53, gw.BAR, gw.LENGTH, gw.classic58
local Q, C2 = 12288, 36

-- 53EDO chord roots per bar (Cmaj7 Am7 Fmaj7 G7), reused from glasswork's bed.
local root = { 53, 39, 22, 31 }

local ostPat = { kind='notes', lengthPpq=Q,
                 specs={ { ppq=0, endppq=4096, vel=96 }, { ppq=6144, endppq=9216, vel=66 } } }
local lfoCurve = { kind='curve', lengthPpq=1000,
                   points={ {ppq=0,val=-1,shape='slow'}, {ppq=500,val=1,shape='slow'} } }

-- One continuous-heavy lane stack on chan 1. Lane 1 bears detune (lane-1 detune
-- holds forward and feeds pb), so it leads the pb fold; `off` spreads the lanes'
-- 53EDO base apart so no two lanes share a pitch in a bar.
local lanes = {
  { off = 53, fx = {{ kind='vibrato', period={1,3}, depth=40, onset=1 }} },           -- pb
  { off = 60, fx = {{ kind='slide',   over={1,2}, target='next' }} },                 -- pb
  { off = 67, fx = {{ kind='lfo', period={4,1}, centre=60, scale=52, pattern=lfoCurve }} }, -- cc1
  { off = 74, fx = {{ kind='autopan', period={2,1}, depth=48 }} },                    -- cc10
  { off = 81, fx = {{ kind='retrig', period={1,4}, ramp=0 },
                    { kind='velPattern', pattern={100,55,70,55} }} },                 -- note chain
  { off = 88, fx = {{ kind='ostinato', pattern=ostPat }} },                           -- note
}

local function build(tm, gm)
  for lane, ln in ipairs(lanes) do
    for bar = 0, 31 do
      local ci, at = (bar % 4) + 1, bar * BAR
      local pit, det = e53(C2, root[ci] + ln.off)
      tm:addEvent{ evType='note', chan=1, pitch=pit, detune=det, vel=80,
                   ppq=at, endppq=at + BAR, lane=lane, fx=ln.fx }
    end
  end
  tm:flush()
end

return { build = build, LENGTH = LENGTH, classic58 = classic58, lanes = #lanes }
