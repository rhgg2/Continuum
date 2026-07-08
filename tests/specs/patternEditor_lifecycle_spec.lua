-- design/fx-patterns.md P3 step c: the checkout lifecycle; see docs/patternEditor.md.
-- Pins mint+materialise (both kinds), the parked item, and dropPool clearing eventMeta's write-through blobs.

local t       = require('support')
local util    = require('util')
local scratch = require('scratch')

-- pa/tv take the real shared facade in production; here the boundary is stubbed
-- (mirrors harness mk's paFacade). open()/close() never route through it.
local fakeFacade = { get = function(name)
  if name == 'arrange' then
    return { ownerTrack = function(take) return reaper.GetMediaItemTake_Track(take) end }
  end
end }

local function noteCount(take) local _, n    = reaper.MIDI_CountEvts(take); return n end
local function ccCount(take)   local _, _, n = reaper.MIDI_CountEvts(take); return n end

local function poolGuidOf(take)
  local item     = reaper.GetMediaItemTake_Item(take)
  local _, chunk = reaper.GetItemStateChunk(item, '', false)
  return chunk:match('POOLEDEVTS%s+({[^}]+})')
end

-- A fresh eventMeta over its own ps reads the same projext mm's flush wrote, so
-- it observes the pool metadata independently of the editor's own instance.
local function poolMeta(guid)
  local em = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
  return em:load(guid)
end

local NOTES = { ost = {
  kind = 'notes', lengthPpq = 960,
  specs = {
    { lane = 1, ppqL = 0,   endppqL = 240, pitch = 60, vel = 100, detune = 0, delay = 0 },
    { lane = 1, ppqL = 240, endppqL = 480, pitch = 64, vel = 100, detune = 0, delay = 0 },
  },
} }

local CURVE = { lfo = {
  kind = 'curve', lengthPpq = 960,
  points = {
    { ppq = 0,   val = 0,    shape = 'linear' },
    { ppq = 480, val = 1,    shape = 'linear' },   -- full-scale +1 exercises the cents scaling
    { ppq = 960, val = -0.5, shape = 'linear' },
  },
} }

-- Build a host stack, seed the library on its ds, hand that ds to a fresh editor.
local function withEditor(harness, library)
  local h = harness.mk()
  h.ds:assign('fxPatterns', library)
  local pe = util.instantiate('patternEditor', { facade = fakeFacade, ds = h.ds })
  return h, pe
end

return {
  {
    name = 'open mints a checkout on scratch and materialises the notes body; close sweeps it',
    run = function(harness)
      local h, pe = withEditor(harness, NOTES)

      pe:open('ost')
      t.truthy(pe:isOpen(), 'the editor is open after open()')
      local take = pe:currentTake()
      t.truthy(take, 'a checkout take is bound on the mini tm')
      local strack = scratch.track()
      t.eq(reaper.CountTrackMediaItems(strack), 1, 'exactly one checkout item parked on scratch')
      t.eq(noteCount(take), 2, 'both note specs materialised onto the checkout')

      local guid = poolGuidOf(take)
      t.truthy(next(poolMeta(guid)), 'materialised notes wrote pool metadata to projext')

      pe:close()
      t.eq(pe:isOpen(), false, 'the editor is dormant after close()')
      t.eq(reaper.CountTrackMediaItems(strack), 0, 'the checkout item is deleted on close')
      t.eq(next(poolMeta(guid)), nil, 'dropPool swept the pool metadata')
    end,
  },

  {
    name = 'a curve body materialises as pb events; close removes the checkout',
    run = function(harness)
      local h, pe = withEditor(harness, CURVE)

      pe:open('lfo')
      local take = pe:currentTake()
      t.eq(ccCount(take), 3, 'all three curve points materialised as pb events')

      local strack = scratch.track()
      pe:close()
      t.eq(pe:isOpen(), false, 'the editor is dormant after close()')
      t.eq(reaper.CountTrackMediaItems(strack), 0, 'the checkout item is deleted on close')
    end,
  },

  {
    name = 'open is a no-op for an unknown pattern name',
    run = function(harness)
      local h, pe = withEditor(harness, NOTES)
      pe:open('nope')
      t.eq(pe:isOpen(), false, 'no checkout is minted for an unknown name')
      t.eq(reaper.CountTrackMediaItems(scratch.track()), 0, 'no item parked on scratch')
    end,
  },

  {
    -- The production shape: trackerPage builds one editor and cycles it. Pins that
    -- close() fully resets -- a fresh checkout, distinct pool guid, body re-materialised.
    name = 'the singleton editor cycles open/close/open, minting a fresh pool each time',
    run = function(harness)
      local h, pe = withEditor(harness, NOTES)
      local strack = scratch.track()

      pe:open('ost')
      local guid1 = poolGuidOf(pe:currentTake())
      t.eq(reaper.CountTrackMediaItems(strack), 1, 'first open mints a checkout')

      pe:close()
      t.eq(reaper.CountTrackMediaItems(strack), 0, 'first close removes it')

      pe:open('ost')
      t.truthy(pe:isOpen(), 're-open on the same instance works')
      local guid2 = poolGuidOf(pe:currentTake())
      t.eq(reaper.CountTrackMediaItems(strack), 1, 'second open mints a fresh checkout')
      t.truthy(guid2 ~= guid1, 'the re-checkout gets a distinct pool guid')
      t.eq(noteCount(pe:currentTake()), 2, 'the body re-materialises on re-open')
    end,
  },
}
