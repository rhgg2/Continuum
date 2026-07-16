-- "Glasswork" -- the macro/generator torture fixture for interval-dirt Phase 0.
--
-- 32 bars, 53EDO, classic58 swing (raw != logical everywhere). Cmaj7 - Am7 -
-- Fmaj7 - G7 in just intonation. Exercises every wild tracker feature:
--   * all 9 generator kinds  (retrig ostinato arp velPattern trill | vibrato
--     slide autopan lfo)
--   * fx chains              (ch5: retrig -> velPattern)
--   * mirror-group canon     (ch15/16: one subject, three staggered instances)
--   * cc11 + channel-AT + poly-AT controllers
--   * 53EDO detune -> dense pb realisation
-- ~1268 model notes, ~16.9k raw events. Complement to the dense HAMMERKLAVIER
-- take: that one is internals/tails-bound (phases 3-4), this one is
-- fx/pbs/ccs-bound at no-op (phases 5-6) and write-bound on a steady edit.
--
-- The CALLER sets temper='53EDO', swing 'c58' global, and length = 32*BAR
-- BEFORE calling build(); this module only authors events. Works from the
-- REAPER bridge (build(page('tracker').tm, page('tracker').gm)) and, once
-- lifted, from the harness. See design/interval-dirt.md.

local BAR, Q, H = 49152, 12288, 24576
local C2 = 36

-- 53EDO step (absolute, from C2 = MIDI 36) -> (MIDI pitch, cents detune).
local function e53(base, steps)
  local c = steps * 1200.0 / 53.0
  local s = math.floor(c / 100 + 0.5)
  return base + s, c - s * 100
end

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- Chord voicings as absolute 53EDO steps from C2, indexed by bar % 4 + 1
-- (Cmaj7, Am7, Fmaj7, G7).
local root  = { 53,  39,  22,  31 }              -- C3  A2  F2  G2   bass
local ten   = { 123, 106, 92,  101 }             -- E4  C4  A3  B3   tenor
local sop   = { 154, 135, 123, 127 }             -- B4  G4  E4  F4   soprano (7ths)
local triad = { {106,123,137}, {92,106,123}, {75,92,106}, {84,101,115} }
local arpCh = { {106,123,137,154}, {92,106,123,135}, {75,92,106,123}, {84,101,115,127} }

local function note(tm, ev) tm:addEvent(ev) end

local function build(tm, gm)
  ----- Harmonic bed: three-voice 53EDO chorale, all 32 bars (ch10-12)
  for i = 0, 31 do
    local ci, at = (i % 4) + 1, i * BAR
    local rp, rd = e53(C2, root[ci]); local tp, td = e53(C2, ten[ci])
    note(tm, { evType='note', chan=10, pitch=rp, detune=rd, vel=70, ppq=at, endppq=at+BAR, lane=1 })
    note(tm, { evType='note', chan=11, pitch=tp, detune=td, vel=58, ppq=at, endppq=at+BAR, lane=1 })
    local sp,  sd  = e53(C2, sop[ci])
    local sp2, sd2 = e53(C2, sop[ci] + 9)        -- whole-tone neighbour, shimmer
    note(tm, { evType='note', chan=12, pitch=sp,  detune=sd,  vel=54, ppq=at,   endppq=at+H,   lane=1 })
    note(tm, { evType='note', chan=12, pitch=sp2, detune=sd2, vel=48, ppq=at+H, endppq=at+BAR, lane=1 })
  end

  ----- Pads: autopan (ch8 -> cc10) and lfo (ch9 -> cc1), bars 0-23
  local autopan  = {{ kind='autopan', period={2,1}, depth=48 }}
  local lfoCurve = { kind='curve', lengthPpq=1000,
                     points={ {ppq=0,val=-1,shape='slow'}, {ppq=500,val=1,shape='slow'} } }
  local lfo = {{ kind='lfo', period={4,1}, centre=60, scale=52, pattern=lfoCurve }}
  for i = 0, 23 do
    local ci, at = (i % 4) + 1, i * BAR
    local rp, rd = e53(C2, root[ci] + 53)
    note(tm, { evType='note', chan=9, pitch=rp, detune=rd, vel=40, ppq=at, endppq=at+BAR, lane=1, fx=lfo })
    local fp, fd = e53(C2, root[ci] + 53 + 31)
    note(tm, { evType='note', chan=8, pitch=fp, detune=fd, vel=38, ppq=at, endppq=at+BAR, lane=1, fx=autopan })
  end

  ----- Groove engine: retrig pulse (ch1) + ostinato bass (ch4), bars 8-31
  local ostPat = { kind='notes', lengthPpq=Q,
                   specs={ { ppq=0, endppq=4096, vel=96 }, { ppq=6144, endppq=9216, vel=66 } } }
  local ostinato = {{ kind='ostinato', pattern=ostPat }}
  for i = 8, 31 do
    local ci, at = (i % 4) + 1, i * BAR
    local dense = i >= 24                         -- tighten to sixteenths at the climax
    local retrig = {{ kind='retrig', period = dense and {1,4} or {1,2}, ramp = dense and -3 or -6 }}
    local pp, pd = e53(C2, root[ci] + 53)
    note(tm, { evType='note', chan=1, pitch=pp, detune=pd, vel=100, ppq=at, endppq=at+BAR, lane=1, fx=retrig })
    local bp, bd = e53(C2, root[ci])
    note(tm, { evType='note', chan=4, pitch=bp, detune=bd, vel=90, ppq=at, endppq=at+BAR, lane=1, fx=ostinato })
  end

  ----- Arp (ch3) chord-per-bar bars 8-23; velPattern chain (ch5) bars 12-19
  local arp = {{ kind='arp', period={1,2}, dir='updown' }}
  for i = 8, 23 do
    local ci, at = (i % 4) + 1, i * BAR
    for lane, step in ipairs(arpCh[ci]) do
      local pit, det = e53(C2, step)
      note(tm, { evType='note', chan=3, pitch=pit, detune=det, vel=72,
                 ppq=at, endppq=at+BAR, lane=lane, fx = (lane==1) and arp or nil })
    end
  end
  local accent = {{ kind='retrig', period={1,4}, ramp=0 }, { kind='velPattern', pattern={100,55,70,55} }}
  local ch5line = { 106,101,92,84, 75,84,92,101 }  -- C B A G F G A B
  for k = 0, 7 do
    local at = (12 + k) * BAR
    local pit, det = e53(C2, ch5line[k+1] + 53)
    note(tm, { evType='note', chan=5, pitch=pit, detune=det, vel=100, ppq=at, endppq=at+BAR, lane=1, fx=accent })
  end

  ----- Melody: vibrato lead (ch6), slide counter (ch7), trill ornament (ch2)
  local vibrato = {{ kind='vibrato', period={1,3}, depth=40, onset=1 }}
  local slide   = {{ kind='slide',   over={1,2}, target='next' }}
  local trill   = {{ kind='trill',   period={1,4}, step=9 }}
  local phrase6 = { 159,176, 168,159, 145,159, 154,168 }   -- vibrato lead arch
  local phrase7 = { 137,123, 123,106, 128,113, 115,101 }   -- slide counter-line
  local phrase2 = { 176,181, 168,176, 159,168, 168,159 }   -- trill line
  -- delay (milli-QN) nudges only the raw note-on: the lead sits behind the
  -- beat, the counter-line leans ahead -- non-uniform raw!=logical on top
  -- of the global swing. Too small to cross an onset (design close q5).
  local function layer(chan, startBar, endBar, phrase, vel, fx, delay)
    for b = startBar, endBar do
      local o = (b - startBar) % 4
      for half = 0, 1 do
        local pit, det = e53(C2, phrase[o*2 + half + 1])
        note(tm, { evType='note', chan=chan, pitch=pit, detune=det, vel=vel, delay=delay,
                   ppq=b*BAR + half*H, endppq=b*BAR + half*H + H, lane=1, fx=fx })
      end
    end
  end
  layer(6, 16, 31, phrase6, 88, vibrato, 40)   -- laid-back lead
  layer(7, 16, 31, phrase7, 72, slide, -25)    -- counter-line leans ahead
  layer(2, 16, 27, phrase2, 80, trill)

  ----- Expression: cc11 swell + channel-AT (ch13), poly-AT chords (ch14)
  local swell = { 24, 96 }
  for b = 16, 31 do
    local ci, at = (b % 4) + 1, b * BAR
    local pp, pd = e53(C2, root[ci] + 31 + 53)
    note(tm, { evType='note', chan=13, pitch=pp, detune=pd, vel=46, ppq=at, endppq=at+BAR, lane=1 })
    for half = 0, 1 do
      note(tm, { evType='cc', chan=13, cc=11, ppq=at + half*H,
                 val=math.min(swell[half+1] + (b % 4) * 6, 127), shape='linear' })
    end
    note(tm, { evType='at', chan=13, ppq=at,   val=20, shape='linear' })
    note(tm, { evType='at', chan=13, ppq=at+H, val=70, shape='linear' })
  end
  for b = 20, 31 do
    local ci, at = (b % 4) + 1, b * BAR
    for lane, step in ipairs(triad[ci]) do
      local pit, det = e53(C2, step)
      note(tm, { evType='note', chan=14, pitch=pit, detune=det, vel=64, ppq=at, endppq=at+BAR, lane=lane })
      note(tm, { evType='pa', chan=14, pitch=pit, ppq=at+2000, vel=30, shape='linear' })
      note(tm, { evType='pa', chan=14, pitch=pit, ppq=at+H,    vel=90, shape='linear' })
    end
  end

  ----- Canon subject on ch15 (must be flushed to earn uuids before markGroup)
  local subj = { 159,176,190,176, 168,181,198,190 }   -- C5 E5 G5 E5 | D5 F5 A5 G5
  for j = 0, 7 do
    local pit, det = e53(C2, subj[j+1])
    note(tm, { evType='note', chan=15, pitch=pit, detune=det, vel=78,
               ppq=24*BAR + j*Q, endppq=24*BAR + j*Q + Q, lane=1 })
  end
  tm:flush()

  ----- Mark the subject and cascade three staggered canon instances.
  -- Gather the flushed lane-1 events (they carry uuid now) straight from the
  -- channel column -- a pure-tm path, no mm handle needed.
  local subject = {}
  for _, e in ipairs(tm:getChannel(15).columns.notes[1].events) do
    subject[#subject+1] = e
  end
  table.sort(subject, function(a, b) return a.ppq < b.ppq end)
  local rect = { ppq = 24*BAR, dur = 2*BAR, chanLo = 15, streams = { [0] = { ['note:1'] = true } } }
  local gid = gm:markGroup(subject, rect)
  for _, a in ipairs({ { ppq=25*BAR, chan=16 }, { ppq=27*BAR, chan=15 }, { ppq=29*BAR, chan=16 } }) do
    gm:newInstance(gid, a)
  end
  tm:flush()
end

return { build = build, e53 = e53, classic58 = classic58, BAR = BAR, LENGTH = 32 * BAR }
