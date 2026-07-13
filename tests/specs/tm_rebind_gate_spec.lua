-- The converged-rebind gate (design/incremental-rebuild.md § gap 3): a rebind whose take is
-- byte-identical to the one mm's model was built from skips both the re-read and the re-derive.
--
-- The gate's observable is work NOT done. Deriving a converged take stages zero writes either
-- way (I8), so equal output proves nothing; object identity does. mm keeps its event records
-- only if it never re-parsed the blob, and tm keeps its column cells only if it never re-derived
-- the channel. The dormant cases pin the dirt sources that the old mark-all-16-on-wholesale
-- blanket used to hide: config, document data, and the trackerMode re-seed at bind.

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- Rewrite the take's document storage behind tm's back -- what a REAPER undo does while the tracker
-- is dormant: the P_EXT blob rewinds, ps watches only the bound take's slots so nothing fires, and
-- ds/cm simply refill their caches at the next setContext. No signal exists for tm to have missed.
local function storageWriteBehindTmsBack(take, name, value)
  local ps = util.instantiate('pextStore')
  local ds = util.instantiate('dataStore', { ps = ps })
  ps:setTake(take)
  ds:assign(name, value)
end

local function note(chan, ppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- mm's own record, not a copy: its identity dies the moment load re-parses the blob.
local function firstRawNote(h)
  for _, raw in h.fm:notesRaw() do return raw end
end

-- tm's column cell: its identity dies the moment the channel re-materialises.
local function firstCell(h, chan)
  return h.tm:getChannel(chan).columns.notes[1].events[1]
end

local function pbOn(h, chan)
  for _, cc in ipairs(h.fm:dump().ccs) do
    if cc.evType == 'pb' and cc.chan == chan then return cc end
  end
end

local function pcsOn(h, chan)
  local out = {}
  for _, cc in ipairs(h.fm:dump().ccs) do
    if cc.evType == 'pc' and cc.chan == chan then out[#out + 1] = { ppq = cc.ppq, val = cc.val } end
  end
  return out
end

return {
  {
    name = 'converged rebind re-reads nothing and re-derives nothing',
    run = function(harness)
      local h = harness.mk{}
      h.tm:addEvent(note(1, 0, 60, { detune = 25 })); h.tm:flush()
      local take = h.tm:currentTake()

      t.truthy(pbOn(h, 1), 'fixture derives an absorber pb, so derivation has something to skip')
      local rawBefore, cellBefore = firstRawNote(h), firstCell(h, 1)

      h.tm:bindTake(nil)      -- the dormant seam: mm keeps the take, cm drops its context
      h.tm:bindTake(take)

      t.truthy(firstRawNote(h) == rawBefore,  'mm kept its event records: the converged blob was never re-parsed')
      t.truthy(firstCell(h, 1) == cellBefore, 'tm carried the frame: no channel re-derived')
    end,
  },

  {
    name = 'a config change made while dormant re-derives on rebind',
    run = function(harness)
      local h = harness.mk{}
      h.tm:addEvent(note(1, 0, 60, { detune = 25 })); h.tm:flush()
      local take   = h.tm:currentTake()
      local before = pbOn(h, 1).val

      h.tm:bindTake(nil)
      h.cm:set('project', 'pbRange', 12)   -- same detune, different raw: the absorber pb must re-scale
      h.tm:bindTake(take)

      t.truthy(pbOn(h, 1).val ~= before, 'the absorber pb was re-derived under the new pbRange')
    end,
  },

  {
    name = 'a swing edit made while dormant reseats raw on rebind',
    run = function(harness)
      local h = harness.mk{ config = { project = { swings = { c58 = classic58 } } } }
      h.tm:addEvent(note(1, 120, 60)); h.tm:flush()   -- the offbeat: where a swing composite actually displaces
      local take = h.tm:currentTake()
      t.eq(firstRawNote(h).ppq, 120, 'raw sits at intent while swing is identity')

      h.tm:bindTake(nil)
      storageWriteBehindTmsBack(take, 'swing', { global = 'c58' })
      h.tm:bindTake(take)

      t.truthy(firstRawNote(h).ppq ~= 120, 'the note re-realised under the swing authored while dormant')
    end,
  },

  {
    name = 'a trackerMode flip across the dormant window re-derives PCs',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 3 },
      } } }
      local take = h.tm:currentTake()
      t.eq(#pcsOn(h, 1), 0, 'no PC stream while trackerMode is off')

      h.tm:bindTake(nil)
      h.tm:bindTake(take, { trackerMode = true })   -- wiring changed while the page was away

      t.deepEq(pcsOn(h, 1), { { ppq = 0, val = 3 } }, 'the rebind synthesised the PC stream')
    end,
  },
}
