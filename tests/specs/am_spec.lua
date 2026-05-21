-- arrangeManager: discovery, slot dictionary, reswing-folded API.

local t = require('support')
local util = require('util')

local function mkAm(harness, opts)
  local h = harness.mk(opts)
  local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
  return h, am
end

-- Seed two arbitrary tracks and a per-track item list. Returns the
-- track tokens so each test can name them. The harness's default
-- bindTake(take1) is unrelated — we manage these via setProjectTracks
-- so am sees them in CountTracks/GetTrack order.
local function seedTracks(h, specs)
  local tracks = {}
  for i, spec in ipairs(specs) do
    local track = 'tr' .. i
    h.reaper:setTrackName(track, spec.name or ('track' .. i))
    tracks[#tracks+1] = track
    for j, item in ipairs(spec.items or {}) do
      local take = 'tr' .. i .. '/take' .. j
      h.reaper:addItem(track, {
        take     = take,
        isMidi   = item.kind == 'midi',
        pos      = item.pos or 0,
        len      = item.len or 1,
        poolGuid = item.poolGuid,
        srcFile  = item.srcFile,
        takeName = item.takeName or '',
      })
    end
  end
  h.reaper:setProjectTracks(tracks)
  return tracks
end

return {
  --------------------------------------------------------------------
  -- Discovery
  --------------------------------------------------------------------
  {
    name = 'projectTracks lists every track in REAPER order with item count',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { name = 'A', items = { { kind = 'midi', poolGuid = '{p1}' } } },
        { name = 'B', items = {} },
        { name = 'C', items = { { kind = 'midi', poolGuid = '{p2}' },
                                { kind = 'midi', poolGuid = '{p3}' } } },
      })
      local rows = am:projectTracks()
      t.eq(#rows, 3, 'three tracks visible')
      t.eq(rows[1].name, 'A')
      t.eq(rows[2].takeCount, 0, 'empty track reports 0 items')
      t.eq(rows[3].takeCount, 2, 'two items on C')
      t.eq(rows[1].slotCount, 0, 'no slots declared yet')
    end,
  },

  {
    name = 'tracksTakes builds take rows with QN range, kind, and orphan slotIdx',
    run = function(harness)
      local h, am = mkAm(harness)
      local tracks = seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, poolGuid = '{p1}', takeName = 'lead' },
                    { kind = 'audio', pos = 4, len = 2, srcFile = '/a.wav', takeName = 'kick' } } },
      })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      t.eq(takes[1].kind, 'midi')
      t.eq(takes[1].startQN, 0)
      t.eq(takes[1].lengthQN, 4)
      t.eq(takes[2].kind, 'audio')
      t.eq(takes[2].startQN, 4)
      t.eq(takes[2].name, 'kick')
      t.eq(takes[1].slotIdx, nil, 'orphan: no matching slot')
      t.eq(takes[2].slotIdx, nil, 'orphan: no matching slot')
      t.eq(takes[1].trackIdx, 0)
      t.truthy(tracks[1])
    end,
  },

  --------------------------------------------------------------------
  -- Slot allocation / dictionary writes
  --------------------------------------------------------------------
  {
    name = 'newMidiSlot allocates lowest-free index; gaps are preserved',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local a = am:newMidiSlot(0, { id = '{x}' })
      local b = am:newMidiSlot(0, { id = '{y}' })
      local c = am:newMidiSlot(0, { id = '{z}' })
      t.eq(a, 0); t.eq(b, 1); t.eq(c, 2)
      am:deleteSlot(0, 1)
      local d = am:newMidiSlot(0, { id = '{w}' })
      t.eq(d, 1, 'fills gap before extending')
    end,
  },

  {
    name = 'newAudioSlot stores path as id',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local idx = am:newAudioSlot(0, '/samples/snare.wav')
      t.eq(idx, 0)
      local slots = am:trackSlots(0)
      t.eq(slots[1].kind, 'audio')
      t.eq(slots[1].id, '/samples/snare.wav')
    end,
  },

  {
    name = 'newAudioSlot rejects empty path',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      t.eq(am:newAudioSlot(0, ''), nil)
      t.eq(am:newAudioSlot(0, nil), nil)
    end,
  },

  --------------------------------------------------------------------
  -- Name resolution (derived per call, first-found wins)
  --------------------------------------------------------------------
  {
    name = 'trackSlots derives slot name from any matching take (first-found wins)',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}', takeName = 'verse' },
                    { kind = 'midi', poolGuid = '{p1}', takeName = 'verse-2' },
                    { kind = 'midi', poolGuid = '{p2}', takeName = 'bridge' } } },
      })
      am:newMidiSlot(0, { id = '{p1}' })
      am:newMidiSlot(0, { id = '{p2}' })
      local slots = am:trackSlots(0)
      t.eq(slots[1].name, 'verse', 'first-found take name')
      t.eq(slots[2].name, 'bridge')
    end,
  },

  {
    name = 'slotForTake resolves slot from take pool guid; nil for orphan',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{orphan}' } } },
      })
      am:newMidiSlot(0, { id = '{p1}' })
      local takes = am:tracksTakes(0)
      t.eq(am:slotForTake(takes[1].take), 0)
      t.eq(am:slotForTake(takes[2].take), nil)
    end,
  },

  --------------------------------------------------------------------
  -- Mutation across instances
  --------------------------------------------------------------------
  {
    name = 'renameSlot writes SetTakeName across every matching item',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}', takeName = 'old' },
                    { kind = 'midi', poolGuid = '{p1}', takeName = 'old' },
                    { kind = 'midi', poolGuid = '{other}', takeName = 'leave-me' } } },
      })
      am:newMidiSlot(0, { id = '{p1}' })
      am:renameSlot(0, 0, 'lead')
      local takes = am:tracksTakes(0)
      t.eq(takes[1].name, 'lead')
      t.eq(takes[2].name, 'lead')
      t.eq(takes[3].name, 'leave-me', 'unrelated take untouched')
    end,
  },

  {
    name = 'deleteSlot removes dict entry; opts.removeInstances=true deletes matching items',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{p2}' } } },
      })
      am:newMidiSlot(0, { id = '{p1}' })
      am:newMidiSlot(0, { id = '{p2}' })

      am:deleteSlot(0, 0)
      t.eq(#am:trackSlots(0), 1, 'slot entry removed from palette')
      t.eq(#am:tracksTakes(0), 3, 'instances left as orphans by default')
      -- The {p1} takes are now orphans (slotIdx nil).
      local takes = am:tracksTakes(0)
      local orphanCount = 0
      for _, tk in ipairs(takes) do
        if tk.slotIdx == nil then orphanCount = orphanCount + 1 end
      end
      t.eq(orphanCount, 2, 'two {p1} instances orphaned')

      am:deleteSlot(0, 1, { removeInstances = true })
      t.eq(#am:tracksTakes(0), 2, '{p2} instance deleted alongside its slot')
    end,
  },

  --------------------------------------------------------------------
  -- Base62 key mapping (0..61 -> '0'..'9','a'..'z','A'..'Z')
  --------------------------------------------------------------------
  {
    name = 'keyForSlot maps 0..61 through util.toBase62',
    run = function(harness)
      local _, am = mkAm(harness)
      t.eq(am:keyForSlot(0),  '0')
      t.eq(am:keyForSlot(9),  '9')
      t.eq(am:keyForSlot(10), 'a')
      t.eq(am:keyForSlot(35), 'z')
      t.eq(am:keyForSlot(36), 'A')
      t.eq(am:keyForSlot(61), 'Z')
    end,
  },

  --------------------------------------------------------------------
  -- Reswing (folded from sequenceManager)
  --------------------------------------------------------------------
  {
    name = 'takesUsing reads usedSwings off each take via cm:readTakeKey',
    run = function(harness)
      local h, am = mkAm(harness)
      -- Use the harness's bound take; arrange one project track that
      -- carries it so projectMidiTakes() can find it.
      local boundTake = 'take1'
      h.reaper:addItem('tr1', {
        take = boundTake, isMidi = true, pos = 0, len = 1, poolGuid = '{harn}',
      })
      h.reaper:setProjectTracks{ 'tr1' }
      h.cm:set('take', 'usedSwings', { ['my-swing'] = true })

      local hits = am:takesUsing('my-swing')
      t.eq(#hits, 1)
      t.eq(hits[1], boundTake)

      local miss = am:takesUsing('other')
      t.eq(#miss, 0)
    end,
  },
}
