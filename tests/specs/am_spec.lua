-- arrangeManager: discovery, slot auto-allocation, placement, reswing.

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
      t.eq(rows[1].slotCount, 1, 'one take auto-materialised one slot')
      t.eq(rows[3].slotCount, 2, 'two distinct pool ids -> two slots')
    end,
  },

  --------------------------------------------------------------------
  -- Auto-materialisation: every grouped take becomes a slot on read
  --------------------------------------------------------------------
  {
    name = 'trackSlots auto-allocates slot indices for live takes',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}', takeName = 'lead' },
                    { kind = 'midi', poolGuid = '{p1}', takeName = 'lead-2' },
                    { kind = 'midi', poolGuid = '{p2}', takeName = 'bass' } } },
      })
      local slots = am:trackSlots(0)
      t.eq(#slots, 2, 'two pool ids -> two slots; pooled takes share one')
      t.eq(slots[1].id, '{p1}')
      t.eq(slots[1].name, 'lead', 'first-found take name wins')
      t.eq(slots[2].id, '{p2}')
      t.eq(slots[2].name, 'bass')
    end,
  },

  {
    name = 'tracksTakes assigns slotIdx to every grouped take',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi',  pos = 0, len = 4, poolGuid = '{p1}', takeName = 'lead' },
                    { kind = 'audio', pos = 4, len = 2, srcFile = '/a.wav', takeName = 'kick' } } },
      })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      t.eq(takes[1].kind, 'midi')
      t.eq(takes[1].startQN, 0)
      t.eq(takes[1].lengthQN, 4)
      t.truthy(takes[1].slotIdx, 'midi take has a slot')
      t.eq(takes[2].kind, 'audio')
      t.eq(takes[2].startQN, 4)
      t.eq(takes[2].name, 'kick')
      t.truthy(takes[2].slotIdx, 'audio take has a slot')
      t.eq(takes[1].slotIdx ~= takes[2].slotIdx, true, 'distinct sources -> distinct slots')
    end,
  },

  {
    name = 'ensureSlots is idempotent — second read does not reallocate',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{p2}' } } },
      })
      local first  = am:trackSlots(0)
      local second = am:trackSlots(0)
      t.eq(first[1].idx, second[1].idx, 'p1 keeps its index across reads')
      t.eq(first[2].idx, second[2].idx, 'p2 keeps its index across reads')
    end,
  },

  --------------------------------------------------------------------
  -- Identity resolution
  --------------------------------------------------------------------
  {
    name = 'slotForTake resolves slot from take pool guid',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{p2}' } } },
      })
      local takes = am:tracksTakes(0)
      t.truthy(am:slotForTake(takes[1].take))
      t.truthy(am:slotForTake(takes[2].take))
      t.eq(am:slotForTake(takes[1].take) ~= am:slotForTake(takes[2].take), true)
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
      local slots = am:trackSlots(0)
      local p1Slot
      for _, s in ipairs(slots) do if s.id == '{p1}' then p1Slot = s.idx end end
      am:renameSlot(0, p1Slot, 'lead')
      local takes = am:tracksTakes(0)
      t.eq(takes[1].name, 'lead')
      t.eq(takes[2].name, 'lead')
      t.eq(takes[3].name, 'leave-me', 'unrelated take untouched')
    end,
  },

  {
    name = 'deleteSlot removes every matching item and prunes the dict entry',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{p1}' },
                    { kind = 'midi', poolGuid = '{p2}' } } },
      })
      local slots = am:trackSlots(0)
      local p1Slot
      for _, s in ipairs(slots) do if s.id == '{p1}' then p1Slot = s.idx end end
      local removed = am:deleteSlot(0, p1Slot)
      t.eq(removed, 2, 'two {p1} takes removed')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 1, 'only the {p2} take remains')
      local slotsAfter = am:trackSlots(0)
      t.eq(#slotsAfter, 1, 'palette no longer carries the {p1} slot')
      t.eq(slotsAfter[1].id, '{p2}')
    end,
  },

  --------------------------------------------------------------------
  -- Placement
  --------------------------------------------------------------------
  {
    name = 'createAndDropMidi mints slot 0, creates a take, names it',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local idx, take = am:createAndDropMidi(0, 4, 2, 'lead')
      t.eq(idx, 0, 'first slot is index 0')
      t.truthy(take, 'returns the new take')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 1)
      t.eq(takes[1].startQN,  4)
      t.eq(takes[1].lengthQN, 2)
      t.eq(takes[1].slotIdx,  0)
      t.eq(takes[1].name,     'lead')
      local slots = am:trackSlots(0)
      t.eq(#slots, 1)
      t.truthy(slots[1].id, 'slot id was harvested from the new pool')
    end,
  },

  {
    name = 'createAndDropMidi allocates lowest-free index across calls',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local a = am:createAndDropMidi(0, 0, 1, 'a')
      local b = am:createAndDropMidi(0, 0, 1, 'b')
      local c = am:createAndDropMidi(0, 0, 1, 'c')
      t.eq(a, 0); t.eq(b, 1); t.eq(c, 2)
      am:deleteSlot(0, 1)
      local d = am:createAndDropMidi(0, 0, 1, 'd')
      t.eq(d, 1, 'fills the gap left by delete')
    end,
  },

  {
    name = 'dropInstance pools to an existing slot',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slot, t1 = am:createAndDropMidi(0, 0, 1, 'lead')
      local t2 = am:dropInstance(0, slot, 4, 1)
      t.eq(am:slotForTake(t1), slot, 'original take pools to its slot')
      t.eq(am:slotForTake(t2), slot, 'second pools to same slot via shared POOLEDEVTS')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      for _, tk in ipairs(takes) do
        t.eq(tk.slotIdx, slot, 'every instance back-links to the slot')
      end
    end,
  },

  {
    name = 'dropInstance returns nil for missing slot or missing track',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      t.eq(am:dropInstance(0, 5, 0, 1), nil, 'no slot at index 5')
      t.eq(am:dropInstance(7, 0, 0, 1), nil, 'no track at index 7')
    end,
  },

  {
    name = 'createAndDropMidi returns nil when no track exists',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      t.eq(am:createAndDropMidi(7, 0, 1, 'x'), nil)
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
