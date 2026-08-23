-- arrangeManager: discovery, slot auto-allocation, placement, reswing.

local t = require('support')
local util = require('util')
local scratch = require('scratch')

local function mkAm(harness, opts)
  local h = harness.mk(opts)
  local em = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
  local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm, eventMeta = em })
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
        srcLen   = item.srcLen,
        poolGuid = item.poolGuid,
        srcFile  = item.srcFile,
        takeName = item.takeName or '',
      })
    end
  end
  h.reaper:setProjectTracks(tracks)
  return tracks
end

local function slotFor(am, trackIdx, id)
  for _, s in ipairs(am:trackSlots(trackIdx)) do if s.id == id then return s end end
end

local function slotAt(am, trackIdx, slotIdx)
  for _, s in ipairs(am:trackSlots(trackIdx)) do if s.idx == slotIdx then return s end end
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

  {
    name = 'hasPlacedTakes ignores parked takes, sees placed instances',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      t.eq(am:hasPlacedTakes(), false, 'empty timeline has no placed takes')
      am:mintParkedTake(0, '00', 4)
      t.eq(am:hasPlacedTakes(), false, 'a parked-only slot is not placed')
      am:createAndDropMidi(0, 0, 2, '00')
      t.truthy(am:hasPlacedTakes(), 'a dropped instance counts as placed')
    end,
  },

  --------------------------------------------------------------------
  -- Identity resolution
  --------------------------------------------------------------------
  {
    name = 'ownerTrack resolves a parked take to its logical track, not scratch',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local live   = am:tracksTakes(0)[1].take
      local slot   = am:mintParkedTake(0, 'fresh', 4)
      local parked = am:takeForSlot(0, slot)
      local logical = h.reaper.GetMediaItemTake_Track(live)
      local _, scratchTrack = scratch.peek()
      t.eq(am:ownerTrack(live),   logical, 'a live take owns via its host track')
      t.eq(am:ownerTrack(parked), logical, 'a parked take owns its logical track')
      t.eq(am:ownerTrack(parked) ~= scratchTrack, true, 'owner is not the scratch host')
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
      am:renameSlot(0, slotFor(am, 0, '{p1}').idx, 'lead')
      local takes = am:tracksTakes(0)
      t.eq(takes[1].name, 'lead')
      t.eq(takes[2].name, 'lead')
      t.eq(takes[3].name, 'leave-me', 'unrelated take untouched')
    end,
  },

  {
    name = 'renameSlot reroots the family, each slot keeping its own ordinal',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0,  poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4,  poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 8,  poolGuid = '{p2}', takeName = 'Bassline (var 1)' },
                    { kind = 'midi', pos = 12, poolGuid = '{p3}', takeName = 'Sausage (var 1)' } } },
      })
      local varSlot = slotFor(am, 0, '{p2}').idx
      am:renameSlot(0, varSlot, 'Kenneth (var 1)')
      t.eq(slotFor(am, 0, '{p2}').name, 'Kenneth (var 1)', 'the slot renamed takes the new root')
      t.eq(slotFor(am, 0, '{p1}').name, 'Kenneth',         'its ordinal-less parent follows')
      t.eq(slotFor(am, 0, '{p3}').name, 'Sausage (var 1)', 'another family is left alone')
      local takes = am:tracksTakes(0)
      t.eq(takes[1].name, 'Kenneth', 'every instance of the parent renamed')
      t.eq(takes[2].name, 'Kenneth')
    end,
  },

  {
    name = 'renameSlot with a changed ordinal renames that slot alone',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, poolGuid = '{p2}', takeName = 'Bassline (var 1)' } } },
      })
      am:renameSlot(0, slotFor(am, 0, '{p2}').idx, 'Bassline (var 7)')
      t.eq(slotFor(am, 0, '{p2}').name, 'Bassline (var 7)', 'renamed as typed')
      t.eq(slotFor(am, 0, '{p1}').name, 'Bassline',         'the family stands where it was')
    end,
  },

  {
    name = 'two slots holding the root plain are namesakes, not a family',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, poolGuid = '{p2}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 8, poolGuid = '{p3}', takeName = 'Bassline (var 1)' } } },
      })
      am:renameSlot(0, slotFor(am, 0, '{p1}').idx, 'Kenneth')
      t.eq(slotFor(am, 0, '{p1}').name, 'Kenneth')
      t.eq(slotFor(am, 0, '{p2}').name, 'Bassline',        'the namesake is left where it is')
      t.eq(slotFor(am, 0, '{p3}').name, 'Kenneth (var 1)', 'the variants follow the slot renamed')
    end,
  },

  {
    name = 'with the root held plain twice, a variant reroots neither',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, poolGuid = '{p2}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 8, poolGuid = '{p3}', takeName = 'Bassline (var 1)' } } },
      })
      am:renameSlot(0, slotFor(am, 0, '{p3}').idx, 'Kenneth (var 1)')
      t.eq(slotFor(am, 0, '{p3}').name, 'Kenneth (var 1)')
      t.eq(slotFor(am, 0, '{p1}').name, 'Bassline', 'no base to carry — two claim the root')
      t.eq(slotFor(am, 0, '{p2}').name, 'Bassline')
    end,
  },

  {
    name = 'an unnamed slot has no family',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, poolGuid = '{p2}' } } },
      })
      am:renameSlot(0, slotFor(am, 0, '{p1}').idx, 'Kenneth')
      t.eq(slotFor(am, 0, '{p1}').name, 'Kenneth')
      t.eq(slotFor(am, 0, '{p2}').name, '', 'the other unnamed slot is not swept up')
    end,
  },

  {
    name = 'the reroot reaches a parked family member',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, poolGuid = '{p1}', takeName = 'Bassline' } } },
      })
      local parked = am:mintParkedTake(0, 'Bassline (var 2)', 4)
      am:renameSlot(0, slotFor(am, 0, '{p1}').idx, 'Kenneth')
      t.eq(slotAt(am, 0, parked).name, 'Kenneth (var 2)', 'the parked keeper followed the root')
    end,
  },

  {
    name = 'renameSlot renames a parked slot through its keeper',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local parked = am:mintParkedTake(0, 'Sketch', 4)
      am:renameSlot(0, parked, 'Kenneth')
      t.eq(slotAt(am, 0, parked).name, 'Kenneth', 'no live instance, and still renamed')
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
      local slot = am:createAndDropMidi(0, 0, 1, 'lead')
      am:dropInstance(0, slot, 4, 1)
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      for _, tk in ipairs(takes) do
        t.eq(tk.slotIdx, slot, 'every instance back-links to the slot')
      end
    end,
  },

  {
    name = 'dropInstance overwrites a take already starting at the drop position',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slotA = am:createAndDropMidi(0, 0, 1, 'lead')   -- A at qn0
      am:dropInstance(0, slotA, 12, 1)                      -- A also at qn12, so A stays live
      local slotB = am:createAndDropMidi(0, 8, 1, 'bass')   -- B at qn8

      local placed = am:dropInstance(0, slotB, 0, 1)        -- drop B over A's qn0 instance
      t.truthy(placed, 'B placed at the occupied position')

      local atZero = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN == 0 then atZero[#atZero+1] = tk end
      end
      t.eq(#atZero, 1, 'a single take occupies the drop position — drop did not stack')
      t.eq(atZero[1].slotIdx, slotB, 'the survivor is the freshly dropped instance')
    end,
  },

  {
    name = 'createAndDropMidi overwrites a take already starting at the create position',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slotA = am:createAndDropMidi(0, 0, 1, 'lead')   -- A at qn0
      am:dropInstance(0, slotA, 12, 1)                      -- keep slot A live at qn12
      local slotB = am:createAndDropMidi(0, 0, 1, 'bass')   -- B minted over A's qn0
      t.truthy(slotB and slotB ~= slotA, 'B minted its own slot')

      local atZero = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN == 0 then atZero[#atZero+1] = tk end
      end
      t.eq(#atZero, 1, 'a single take occupies qn0 — create did not stack')
      t.eq(atZero[1].slotIdx, slotB, 'the survivor is the freshly created instance')
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
    name = 'duplicateTake clones a MIDI take into a pooled sibling',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slot  = am:createAndDropMidi(0, 0, 2, 'lead')
      am:duplicateTake(am:tracksTakes(0)[1], 6)
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'original survives, clone added')
      local cloneShape
      for _, tk in ipairs(takes) do
        if tk.startQN == 6 then cloneShape = tk end
      end
      t.eq(cloneShape ~= nil, true, 'clone placed at qnPos 6')
      t.eq(cloneShape.slotIdx, slot, 'clone pools to the source take\'s slot')
      t.eq(cloneShape.lengthQN, 2, 'clone copies the source length')
    end,
  },

  {
    name = 'dropInstance and duplicateTake name the new take after the slot',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slot = am:createAndDropMidi(0, 0, 2, 'lead')
      local dropped = am:dropInstance(0, slot, 8)
      t.eq(h.reaper.GetTakeName(dropped), 'lead',
           'a placed instance inherits the slot name')
      local clone = am:duplicateTake(am:tracksTakes(0)[1], 16)
      t.eq(h.reaper.GetTakeName(clone), 'lead',
           'a duplicate carries the original take name')
    end,
  },

  {
    name = 'duplicateTake returns nil for a missing track',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      am:createAndDropMidi(0, 0, 1, 'x')
      local shape = am:tracksTakes(0)[1]
      shape.trackIdx = 7
      t.eq(am:duplicateTake(shape, 4), nil, 'no track at index 7')
    end,
  },

  {
    name = 'dropInstance carries the sibling MIDI events into the new instance',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slot, t1 = am:createAndDropMidi(0, 0, 1, 'lead')
      h.reaper.MIDI_SetAllEvts(t1, 'EVTS-BLOB')
      local t2 = am:dropInstance(0, slot, 4, 1)
      t.truthy(t2, 'second instance created')
      local _, blob = h.reaper.MIDI_GetAllEvts(t2, '')
      t.eq(blob, 'EVTS-BLOB', 'new pooled instance starts with the pool events, not empty')
    end,
  },

  {
    name = 'duplicateTake carries the source MIDI events into the clone',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      am:createAndDropMidi(0, 0, 2, 'lead')
      local src = am:tracksTakes(0)[1]
      h.reaper.MIDI_SetAllEvts(src.take, 'EVTS-BLOB')
      local clone = am:duplicateTake(src, 6)
      t.truthy(clone, 'clone created')
      local _, blob = h.reaper.MIDI_GetAllEvts(clone, '')
      t.eq(blob, 'EVTS-BLOB', 'pooled clone starts with the source events, not empty')
    end,
  },

  {
    name = 'startIsClear only collides on an exact start match (item ~= exceptItem)',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = {
          { kind = 'midi', pos = 0, len = 2, poolGuid = '{a}' },
          { kind = 'midi', pos = 8, len = 2, poolGuid = '{b}' },
        } },
      })
      t.eq(am:startIsClear(0, 3, nil),  true,  'a free start position is clear')
      t.eq(am:startIsClear(0, 1, nil),  true,  'mid-take is fine — only start-collision blocks')
      t.eq(am:startIsClear(0, 0, nil),  false, 'another take starts here — blocked')
      t.eq(am:startIsClear(0, 8, nil),  false, 'another take starts here — blocked')
      local first = am:tracksTakes(0)[1]
      t.eq(am:startIsClear(0, 0, first.item), true, 'exceptItem excludes the take itself')
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
    name = 'takesUsing scans each take swing map (ds) for the named swing',
    run = function(harness)
      local h, am = mkAm(harness)
      -- Use the harness's bound take; arrange one project track that
      -- carries it so projectMidiTakes() can find it.
      local boundTake = 'take1'
      h.reaper:addItem('tr1', {
        take = boundTake, isMidi = true, pos = 0, len = 1, poolGuid = '{harn}',
      })
      h.reaper:setProjectTracks{ 'tr1' }
      h.ds:assign('swing', { global = 'my-swing' })

      local hits = am:takesUsing('my-swing')
      t.eq(#hits, 1)
      t.eq(hits[1], boundTake)

      local miss = am:takesUsing('other')
      t.eq(#miss, 0)
    end,
  },
  {
    name = 'tempersInUse unions take/project temper names, minus the 12EDO floor',
    run = function(harness)
      local h, am = mkAm(harness)
      local boundTake = 'take1'
      h.reaper:addItem('tr1', {
        take = boundTake, isMidi = true, pos = 0, len = 1, poolGuid = '{harn}',
      })
      h.reaper:setProjectTracks{ 'tr1' }
      h.cm:set('take', 'temper', 'meantone')
      h.cm:set('project', 'temper', 'meantone')

      local inUse = am:tempersInUse()
      t.truthy(inUse['meantone'], 'a take/project temper is reported in use')
      t.eq(inUse['12EDO'], nil, 'the 12EDO floor is excluded')
    end,
  },

  --------------------------------------------------------------------
  -- Per-take edits
  --------------------------------------------------------------------
  --------------------------------------------------------------------
  -- Natural length + relayout
  --------------------------------------------------------------------
  {
    name = 'tracksTakes relayouts on read: an OPEN take grows to its source length',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 2, srcLen = 6, poolGuid = '{p1}' } } },
      })
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.naturalLenQN, 6, 'default natural = source length')
      t.eq(tk.lengthQN,     6, 'build-time relayout grows the OPEN take from the seeded 2 to its 6-QN source')
    end,
  },
  {
    name = 'build relayout: OPEN takes fill to source; an earlier one capped at its gap (no overlap)',
    run = function(harness)
      local h, am = mkAm(harness)
      -- Two adjacent pooled instances whose shared source (8) outruns each seeded item.
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 8, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 8, poolGuid = '{p1}' } } },
      })
      local takes = am:tracksTakes(0)
      t.eq(takes[1].lengthQN, 4, 'earlier OPEN take capped at the gap to its neighbour — never overlaps')
      t.eq(takes[2].lengthQN, 8, 'last OPEN take grows to the full source')
    end,
  },
  {
    name = 'build relayout: an OPEN take whose item outruns its shrunk source is pulled back',
    run = function(harness)
      local h, am = mkAm(harness)
      -- Models a sibling left long after Take Properties shrank the shared source.
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 8, srcLen = 4, poolGuid = '{p1}' } } },
      })
      t.eq(am:tracksTakes(0)[1].lengthQN, 4, 'rendered shrinks to source on read, not left at the stale 8')
    end,
  },

  {
    name = 'a later take truncates an earlier one; deleting the later regrows it',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 8, srcLen = 8, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      -- Trigger an explicit relayout via a no-op move on the second take.
      am:moveTake(am:tracksTakes(0)[2], 0)
      local takes = am:tracksTakes(0)
      t.eq(takes[1].lengthQN, 4, 'first take truncated to the second\'s start')
      t.eq(takes[1].naturalLenQN, 8, 'natural is still 8 — only rendered shrinks')
      am:deleteTake(takes[2])
      t.eq(am:tracksTakes(0)[1].lengthQN, 8, 'regrows to natural after the blocker is gone')
    end,
  },

  {
    name = 'resizeTake stores a numeric natural; ≥ source demotes back to util.OPEN',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      am:resizeTake(am:tracksTakes(0)[1], 2)
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.lengthQN,     2, 'rendered shrinks to the new natural')
      t.eq(tk.naturalLenQN, 2, 'natural recorded')
      am:resizeTake(am:tracksTakes(0)[1], 6)
      tk = am:tracksTakes(0)[1]
      t.eq(tk.lengthQN,     4, 'rendered capped at source')
      t.eq(tk.naturalLenQN, 4, 'natural demoted to OPEN — effective = source')
      t.eq(h.ds:getAt(tk.take, 'arrangeNaturalLenQN'), nil,
           'OPEN persists as a missing key, not a stored math.huge')
    end,
  },
  {
    name = 'audio take longer than its source keeps its length across a move',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'audio', pos = 0, len = 8, srcLen = 4,
                      srcFile = 'loop.wav' } } },
      })
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.naturalLenQN, 8, 'natural = item length, not the 4-QN source')
      am:moveTake(tk, 2)
      local moved = am:tracksTakes(0)[1]
      t.eq(moved.startQN,  2, 'moved to row 2')
      t.eq(moved.lengthQN, 8, 'still 8 QN after relayout — no snap to source')
      t.eq(h.ds:getAt(moved.take, 'arrangeNaturalLenQN'), 8,
           'length captured as the stored natural')
    end,
  },
  {
    name = 'trimmed audio take keeps its trim across a move (no balloon to source)',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'audio', pos = 0, len = 4, srcLen = 10,
                      srcFile = 'long.wav' } } },
      })
      t.eq(am:tracksTakes(0)[1].naturalLenQN, 4, 'natural = the 4-QN trim, not the 10-QN source')
      am:moveTake(am:tracksTakes(0)[1], 2)
      local moved = am:tracksTakes(0)[1]
      t.eq(moved.startQN,  2, 'moved to row 2')
      t.eq(moved.lengthQN, 4, 'still 4 QN — does not balloon to the source length')
    end,
  },

  {
    name = 'moveTake shifts start; refused on start-collision; returns ok flag',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 4, len = 2, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 8, len = 2, poolGuid = '{p2}' } } },
      })
      t.eq(am:moveTake(am:tracksTakes(0)[1], 3), true,  'free start — move succeeds')
      t.eq(am:tracksTakes(0)[1].startQN, 7)
      t.eq(am:moveTake(am:tracksTakes(0)[1], 1), false, 'would collide with {p2} at 8')
      t.eq(am:tracksTakes(0)[1].startQN, 7, 'stays put on collision')
    end,
  },

  {
    name = 'resizeTake writes natural; rendered is min(natural, source, gap)',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 4, len = 2, srcLen = 8, poolGuid = '{p1}' } } },
      })
      am:resizeTake(am:tracksTakes(0)[1], 5)
      local resized = am:tracksTakes(0)[1]
      t.eq(resized.startQN,  4, 'start edge fixed')
      t.eq(resized.lengthQN, 5, 'rendered tracks natural under source cap')
      t.eq(resized.naturalLenQN, 5, 'natural recorded')
    end,
  },

  {
    name = 'deleteTake removes the item, leaving the other take intact',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 1, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 1, poolGuid = '{p2}' } } },
      })
      am:deleteTake(am:tracksTakes(0)[1])
      local takes = am:tracksTakes(0)
      t.eq(#takes, 1, 'one take left after delete')
      t.eq(takes[1].startQN, 4, 'the surviving take is the other one')
    end,
  },

  -- Slot parking lifecycle (a slot outlives its last live instance)
  --------------------------------------------------------------------
  {
    name = 'deleteTake parks a slot\'s last instance; the slot survives, greyed',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}', takeName = 'lead' } } },
      })
      am:deleteTake(am:tracksTakes(0)[1])
      t.eq(#am:tracksTakes(0), 0, 'no live take left on the track')
      local slots = am:trackSlots(0)
      t.eq(#slots, 1, 'the slot survives with no live instance')
      t.eq(slots[1].id, '{p1}')
      t.eq(slots[1].name, 'lead', 'name taken from the parked keeper')
      t.eq(slots[1].parked, true, 'slot flagged parked for greying')
      local _, scratchTrack = scratch.peek()
      t.truthy(scratchTrack, 'a scratch track was minted to hold the park')
      t.eq(h.reaper.CountTrackMediaItems(scratchTrack), 1, 'the item is parked on it')
    end,
  },

  {
    name = 'deleteTake of a non-last instance deletes outright (no park)',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, poolGuid = '{p1}' } } },
      })
      am:deleteTake(am:tracksTakes(0)[1])
      t.eq(#am:tracksTakes(0), 1, 'the sibling instance remains live')
      t.eq(am:trackSlots(0)[1].parked, false, 'slot still has a live instance')
      -- Scratch may exist regardless (it hosts the projext-undo mirror); the
      -- pin is that nothing was PARKED there.
      local _, scratchTrack = scratch.peek()
      t.eq(scratchTrack and h.reaper.CountTrackMediaItems(scratchTrack) or 0, 0,
           'nothing parked on scratch')
    end,
  },

  {
    name = 're-dropping from a parked slot re-materialises off the keeper',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slot, take = am:createAndDropMidi(0, 0, 2, 'lead')
      h.reaper.MIDI_SetAllEvts(take, 'EVTS-BLOB')
      am:deleteTake(am:tracksTakes(0)[1])           -- park the only instance
      t.eq(#am:tracksTakes(0), 0, 'parked: nothing live')
      local back = am:dropInstance(0, slot, 8)
      t.truthy(back, 'a fresh instance drops from the parked keeper')
      t.eq(am:tracksTakes(0)[1].slotIdx, slot, 'it pools to the same slot')
      local _, blob = h.reaper.MIDI_GetAllEvts(back, '')
      t.eq(blob, 'EVTS-BLOB', 'events came from the parked sibling')
    end,
  },

  {
    name = 'deleteSlot forever-deletes: live instances and the parked keeper',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local slot = am:trackSlots(0)[1].idx
      am:deleteTake(am:tracksTakes(0)[1])           -- park it (slot survives)
      t.eq(#am:trackSlots(0), 1, 'slot parked, still present')
      am:deleteSlot(0, slot)
      t.eq(#am:trackSlots(0), 0, 'slot is gone for good')
      local _, scratchTrack = scratch.peek()
      t.eq(h.reaper.CountTrackMediaItems(scratchTrack), 0, 'the parked keeper was purged')
    end,
  },

  {
    name = 'deleteSlot forever-deletes the pool per-event metadata',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' } } },
      })
      local tk = am:tracksTakes(0)[1]
      t.seedMeta(tk.take, 1, { detune = -50 })
      local slot = am:trackSlots(0)[1].idx
      am:deleteSlot(0, slot)
      t.eq(next(t.loadMeta(tk.take)), nil, 'pool metadata gone with the slot')
    end,
  },

  {
    name = 'mintParkedTake shows the new slot at once; isParkedTake flags scratch-hosted takes',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local live = am:tracksTakes(0)[1].take
      local slot, minted = am:mintParkedTake(0, 'fresh', 4)
      t.truthy(slot, 'a parked slot was minted')
      t.eq(am:takeForSlot(0, slot), minted, 'the minted take comes back with its slot')
      t.eq(#am:trackSlots(0), 2, 'the new slot is visible immediately — cache invalidated on mint')
      local parked = am:takeForSlot(0, slot)
      t.truthy(parked, 'the parked take resolves through its slot')
      t.eq(am:isParkedTake(parked), true, 'minted take hosts on scratch — parked')
      t.eq(am:isParkedTake(live),   false, 'a live grid take is not parked')
    end,
  },

  --------------------------------------------------------------------
  -- vary
  --------------------------------------------------------------------
  {
    name = 'vary replaces the instance with one of a fresh variant slot',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' } } },
      })
      local src = am:tracksTakes(0)[2]
      t.seedMeta(src.take, 1, { detune = -50 })
      local slotIdx, take = am:vary(src)
      t.truthy(slotIdx, 'a variant slot was minted')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'the instance was replaced, not added to')
      local below
      for _, tk in ipairs(takes) do if tk.startQN == 4 then below = tk end end
      t.truthy(below, 'a take still stands at the start QN')
      t.eq(below.take, take, 'the returned take is the one on the grid')
      t.eq(below.slotIdx, slotIdx, 'it is an instance of the variant slot')
      t.eq(below.name, 'Bassline (var 1)', 'named from the parent root')
      t.eq(below.lengthQN, 4, 'the variant carries the source length')
      t.eq(#am:trackSlots(0), 2, 'the parent slot survives with its other instance')
      t.eq(t.loadMeta(below.take)[1].detune, -50, 'the fresh pool forked the metadata')
    end,
  },

  {
    name = 'vary numbers from the family high-water mark; a variant of a variant joins the family',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 8, len = 4, srcLen = 4, poolGuid = '{p2}', takeName = 'Bassline (var 3)' } } },
      })
      local src = am:tracksTakes(0)[2]
      local _, take = am:vary(src)
      t.eq(am:findTake(take).name, 'Bassline (var 4)', 'one past the family high-water mark')
    end,
  },

  {
    name = 'vary refuses on a slot with a single instance',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' } } },
      })
      t.eq(am:vary(am:tracksTakes(0)[1]), nil, 'nothing to diverge from')
      t.eq(#am:trackSlots(0), 1, 'no slot minted')
    end,
  },

  --------------------------------------------------------------------
  -- stepVariant
  --------------------------------------------------------------------
  {
    name = 'stepVariant moves the placement onto the next slot of the family',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 8, len = 4, srcLen = 4, poolGuid = '{p2}', takeName = 'Bassline (var 1)' } } },
      })
      local src = am:tracksTakes(0)[2]
      local slotIdx, take = am:stepVariant(src, 1)
      t.truthy(slotIdx, 'the family neighbour was found')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 3, 'the placement moved, nothing was added')
      local moved
      for _, tk in ipairs(takes) do if tk.startQN == 4 then moved = tk end end
      t.eq(moved.take, take, 'the returned take is the one on the grid')
      t.eq(moved.slotIdx, slotIdx, 'it is an instance of the variant slot')
      t.eq(moved.name, 'Bassline (var 1)', 'the placement now plays the variant')
      t.eq(#am:trackSlots(0), 2, 'no slot was minted')
    end,
  },

  {
    name = 'stepVariant past the last of the family varies',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}', takeName = 'Bassline (var 1)' },
                    { kind = 'midi', pos = 8, len = 4, srcLen = 4, poolGuid = '{p2}', takeName = 'Bassline (var 1)' } } },
      })
      local last = am:tracksTakes(0)[3]
      local slotIdx, take = am:stepVariant(last, 1)
      t.truthy(slotIdx, 'a variant slot was minted')
      t.eq(#am:trackSlots(0), 3, 'the palette grew by it')
      t.eq(am:findTake(take).name, 'Bassline (var 2)', 'one past the family high-water mark')
    end,
  },

  {
    name = 'stepVariant off the front of the family does nothing',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' } } },
      })
      local root = am:tracksTakes(0)[1]
      t.eq(am:stepVariant(root, -1), nil, 'the plain root has nothing before it')
      t.eq(#am:tracksTakes(0), 2, 'both placements stand where they did')
      t.eq(#am:trackSlots(0), 1, 'no slot minted')
    end,
  },

  {
    name = 'stepping back off a variant parks it; stepping on again brings it live',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' } } },
      })
      local varSlot = am:vary(am:tracksTakes(0)[2])
      local function takeAt(qn)
        for _, tk in ipairs(am:tracksTakes(0)) do if tk.startQN == qn then return tk end end
      end

      local backSlot = am:stepVariant(takeAt(4), -1)
      t.eq(takeAt(4).slotIdx, backSlot, 'the placement returned to the root slot')
      t.eq(slotAt(am, 0, varSlot).parked, true, 'the variant it left has no live instance')

      local onSlot = am:stepVariant(takeAt(4), 1)
      t.eq(onSlot, varSlot, 'stepping forward finds the variant again')
      t.eq(takeAt(4).slotIdx, varSlot, 'and the placement plays it')
      t.eq(slotAt(am, 0, varSlot).parked, false, 'the keeper came back onto the grid')
    end,
  },

  {
    name = 'a variant with two namesake bases steps forward but not back',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}', takeName = 'Bassline' },
                    { kind = 'midi', pos = 8, len = 4, srcLen = 4, poolGuid = '{p3}', takeName = 'Bassline (var 1)' },
                    { kind = 'midi', pos = 12, len = 4, srcLen = 4, poolGuid = '{p4}', takeName = 'Bassline (var 2)' } } },
      })
      local function takeAt(qn)
        for _, tk in ipairs(am:tracksTakes(0)) do if tk.startQN == qn then return tk end end
      end
      local var1 = takeAt(8).slotIdx
      t.eq(am:stepVariant(takeAt(8), -1), nil, 'no base to step back to — two claim the root')
      t.eq(am:stepVariant(takeAt(0), 1), var1, 'a namesake still steps forward into the variants')
      t.eq(takeAt(4).name, 'Bassline', 'the other namesake was left alone')
    end,
  },

  --------------------------------------------------------------------
  -- Boot cursor
  --------------------------------------------------------------------
  {
    name = 'findTake resolves a REAPER take handle back to its grid take-shape',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 2, poolGuid = '{p1}' } } },
        { items = { { kind = 'midi', pos = 4, len = 1, poolGuid = '{p2}' } } },
      })
      local target = am:tracksTakes(1)[1]
      local found  = am:findTake(target.take)
      t.truthy(found, 'the take is found')
      t.eq(found.trackIdx, 1)
      t.eq(found.startQN,  4)
      t.eq(am:findTake('no-such-take'), nil, 'an unknown handle resolves to nil')
      t.eq(am:findTake(nil),            nil, 'a nil handle resolves to nil')
    end,
  },

  {
    name = 'initialCursor reads the selected item: its take track and start',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = {} },
        { items = { { kind = 'midi', pos = 6, len = 1, poolGuid = '{p1}' } } },
      })
      local target = am:tracksTakes(1)[1]
      h.reaper.SetMediaItemSelected(target.item, true)
      local trackIdx, qn = am:initialCursor()
      t.eq(trackIdx, 1, 'column is the selected take track')
      t.eq(qn,       6, 'row qn is the selected take start')
    end,
  },

  {
    name = 'initialCursor falls back to the edit cursor and selected track',
    run = function(harness)
      local h, am = mkAm(harness)
      local tracks = seedTracks(h, { { items = {} }, { items = {} } })
      h.reaper:setCursor(12)
      h.reaper:setSelectedTracks{ tracks[2] }
      local trackIdx, qn = am:initialCursor()
      t.eq(trackIdx, 1,  'column is the selected track index, 0-based')
      t.eq(qn,       12, 'row qn is the edit-cursor position')
    end,
  },

  {
    name = 'initialCursor defaults to track 0 when nothing is selected',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      h.reaper:setCursor(3)
      local trackIdx, qn = am:initialCursor()
      t.eq(trackIdx, 0, 'column defaults to 0')
      t.eq(qn,       3, 'row qn is still the edit cursor')
    end,
  },

  --------------------------------------------------------------------
  -- Transport — edit cursor, loop range, play head, project end
  --------------------------------------------------------------------
  {
    name = 'editCursorQN reads the REAPER edit cursor',
    run = function(harness)
      local h, am = mkAm(harness)
      h.reaper:setCursor(12)
      t.eq(am:editCursorQN(), 12, 'edit cursor qn')
    end,
  },

  {
    name = 'setEditCursorQN moves the REAPER edit cursor',
    run = function(harness)
      local _, am = mkAm(harness)
      am:setEditCursorQN(8)
      t.eq(am:editCursorQN(), 8, 'edit cursor follows the write')
    end,
  },

  {
    name = 'loopRangeQN returns the project loop range',
    run = function(harness)
      local h, am = mkAm(harness)
      h.reaper:setLoopRange(2, 6)
      local loQN, hiQN = am:loopRangeQN()
      t.eq(loQN, 2, 'loop start qn')
      t.eq(hiQN, 6, 'loop end qn')
    end,
  },

  {
    name = 'loopRangeQN is nil when no loop is set',
    run = function(harness)
      local _, am = mkAm(harness)
      t.falsy(am:loopRangeQN(), 'no loop -> nil')
    end,
  },

  {
    name = 'setLoopRangeQN writes the project loop range',
    run = function(harness)
      local _, am = mkAm(harness)
      am:setLoopRangeQN(3, 7)
      local loQN, hiQN = am:loopRangeQN()
      t.eq(loQN, 3, 'loop start follows the write')
      t.eq(hiQN, 7, 'loop end follows the write')
    end,
  },

  {
    name = 'loopTo brackets a span: loop range, repeat on, cursor at its start',
    run = function(harness)
      local h, am = mkAm(harness)
      am:loopTo(4, 8)
      t.deepEq({ am:loopRangeQN() }, { 4, 8 }, 'loop range is the span')
      t.eq(h.reaper.GetSetRepeat(-1), 1, 'repeat on, so the range loops')
      t.eq(am:editCursorQN(), 4, 'edit cursor at the span start')
      t.eq(h.reaper._state.playState, 0, 'a stopped transport stays stopped')
    end,
  },

  {
    name = 'loopTo leaves the cursor alone when the play head is inside the span',
    run = function(harness)
      local h, am = mkAm(harness)
      am:setEditCursorQN(1)
      h.reaper:setPlay(true, 5)
      am:loopTo(4, 8)
      t.deepEq({ am:loopRangeQN() }, { 4, 8 }, 'the span is still bracketed')
      t.eq(h.reaper.GetSetRepeat(-1), 1, 'repeat on, so the range loops')
      t.eq(am:editCursorQN(), 1, 'a placement already sounding is not pulled back to its start')
    end,
  },

  {
    name = 'clearLoopRange removes the project loop range',
    run = function(harness)
      local h, am = mkAm(harness)
      h.reaper:setLoopRange(2, 6)
      am:clearLoopRange()
      t.falsy(am:loopRangeQN(), 'cleared loop -> nil')
    end,
  },

  {
    name = 'playPositionQN is nil when the transport is stopped',
    run = function(harness)
      local _, am = mkAm(harness)
      t.falsy(am:playPositionQN(), 'stopped -> nil')
    end,
  },

  {
    name = 'playPositionQN returns the play head qn while playing',
    run = function(harness)
      local h, am = mkAm(harness)
      h.reaper:setPlay(true, 9)
      t.eq(am:playPositionQN(), 9, 'play head qn')
    end,
  },

  --------------------------------------------------------------------
  -- Seeking an instance of a slot
  --------------------------------------------------------------------
  {
    name = 'seekInstance takes the instance whose rendered span holds qn',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 8, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local bound = am:tracksTakes(0)[1].take
      local inst, contains = am:seekInstance(bound, 5, false)
      t.eq(inst.startQN, 4, 'the second instance holds qn 5')
      t.eq(contains, true, 'and reports containment')
      t.eq(inst.lengthQN, 4, 'rendered span comes with it')
      t.eq(inst.naturalLenQN, 4, 'natural span comes with it')
    end,
  },

  {
    name = 'seekInstance spans are half-open — the end belongs to the next',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local bound = am:tracksTakes(0)[1].take
      t.eq(am:seekInstance(bound, 4, false).startQN, 4, 'the boundary belongs to the later instance')
    end,
  },

  {
    name = 'seekInstance from a gap travels forwards by default, backwards when asked',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0,  len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 12, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local bound = am:tracksTakes(0)[1].take
      local fwd, fwdContains = am:seekInstance(bound, 6, false)
      t.eq(fwd.startQN, 12, 'forwards reaches the later instance')
      t.eq(fwdContains, false, 'which does not contain qn')
      t.eq(am:seekInstance(bound, 6, true).startQN, 0, 'backwards reaches the earlier one')
    end,
  },

  {
    name = 'seekInstance falls back to the other direction when its own is empty',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local bound = am:tracksTakes(0)[1].take
      t.eq(am:seekInstance(bound, 20, false).startQN, 4, 'nothing ahead, so the last one behind')
      t.eq(am:seekInstance(bound, -5, true).startQN, 0, 'nothing behind, so the first one ahead')
    end,
  },

  {
    name = 'seekInstance ignores instances of other slots',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0,  len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4,  len = 4, srcLen = 4, poolGuid = '{p2}' },
                    { kind = 'midi', pos = 12, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local bound = am:tracksTakes(0)[1].take
      local inst, contains = am:seekInstance(bound, 5, false)
      t.eq(inst.startQN, 12, 'the other slot is not a candidate, so the seek passes over it')
      t.eq(contains, false, 'sitting inside another slot is not containment')
    end,
  },

  {
    name = 'seekInstance matches on the rendered span, not the source span',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0,  len = 8, srcLen = 8, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4,  len = 4, srcLen = 4, poolGuid = '{p2}' },
                    { kind = 'midi', pos = 12, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local bound = am:tracksTakes(0)[1].take
      t.eq(am:tracksTakes(0)[1].lengthQN, 4, 'the bound instance is cut by its neighbour')
      t.eq(select(2, am:seekInstance(bound, 6, false)), false,
           'qn past the cut is outside it, though the source still runs')
    end,
  },

  {
    name = 'seekInstance is nil for a slot whose only take is parked',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local slot   = am:mintParkedTake(0, 'fresh', 4)
      local parked = am:takeForSlot(0, slot)
      t.falsy(am:seekInstance(parked, 2, false), 'a parked slot has no instance to reach')
      t.truthy(am:seekInstance(am:tracksTakes(0)[1].take, 2, false), 'its live neighbour still does')
    end,
  },

  {
    name = 'projectEndQN is 0 for a project with no items',
    run = function(harness)
      local _, am = mkAm(harness)
      t.eq(am:projectEndQN(), 0, 'empty project ends at 0')
    end,
  },

  {
    name = 'projectEndQN reports the largest take end across all tracks',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4,  poolGuid = '{p1}' },
                    { kind = 'midi', pos = 8, len = 3,  poolGuid = '{p2}' } } },
        { items = { { kind = 'midi', pos = 2, len = 20, poolGuid = '{p3}' } } },
      })
      t.eq(am:projectEndQN(), 22, 'the last take end wins, across tracks')
    end,
  },

  --------------------------------------------------------------------
  -- The append point: freeSpan, and the below-trio
  --------------------------------------------------------------------
  {
    name = 'freeSpan is the gap to the next take, and unbounded past the last',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 6, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      t.eq(am:freeSpan(0, 4),  2,         'the gap from QN 4 up to the neighbour at QN 6')
      t.eq(am:freeSpan(0, 6),  0,         'a take starting here leaves no span at all')
      t.eq(am:freeSpan(0, 10), math.huge, 'nothing downstream — unbounded')
    end,
  },

  {
    name = 'duplicateBelow places a pooled clone at the append point',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local src   = am:tracksTakes(0)[1]
      local clone = am:duplicateBelow(src)
      t.truthy(clone, 'clone returned')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      local below
      for _, tk in ipairs(takes) do if tk.startQN == 4 then below = tk end end
      t.truthy(below, 'second take lands at the rendered end of the first')
      t.eq(below.slotIdx, src.slotIdx, 'pooled — same slot as the source')
      t.eq(below.name,    'lead',       'pooled clone keeps the source name')
    end,
  },

  {
    name = 'duplicateBelow refuses where a truncating neighbour leaves no room',
    run = function(harness)
      local h, am = mkAm(harness)
      -- upstream natural=8, downstream at QN 4 → relayout truncates upstream's
      -- rendered span to 4. The append point is that rendered end, so the
      -- neighbour sits on it and no room is left for a natural-length copy.
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 8, srcLen = 8, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      am:moveTake(am:tracksTakes(0)[2], 0)    -- nudge relayout to truncate
      local src = am:tracksTakes(0)[1]
      t.eq(src.lengthQN, 4, 'rendered is truncated')
      t.eq(src.naturalLenQN, 8, 'natural still 8')
      t.eq(am:duplicateBelow(src), nil, 'the copy would come out truncated, so it is refused')
      t.eq(#am:tracksTakes(0), 2, 'no take added')
    end,
  },

  {
    name = 'duplicateBelow refuses where the gap is shorter than the natural length',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 6, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      local src = am:tracksTakes(0)[1]
      t.eq(src.lengthQN, 4, 'untruncated: the source ends before the neighbour starts')
      t.eq(am:duplicateBelow(src), nil, 'a 2 QN gap will not hold a 4 QN copy')
      t.eq(#am:tracksTakes(0), 2, 'no take added')
    end,
  },

  {
    name = 'duplicateBelow refuses on exact-start collision at the destination',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      local src = am:tracksTakes(0)[1]
      t.eq(am:duplicateBelow(src), nil, 'downstream already starts at QN 4')
      t.eq(#am:tracksTakes(0), 2, 'no take added')
    end,
  },

  {
    name = 'duplicateBelow refuses on audio takes',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'audio', pos = 0, len = 4, srcFile = '/a.wav' } } },
      })
      local src = am:tracksTakes(0)[1]
      t.eq(am:duplicateBelow(src), nil, 'audio refused silently')
      t.eq(#am:tracksTakes(0), 1)
    end,
  },

  {
    name = 'duplicateUnpooledBelow mints a fresh slot and copies the MIDI blob',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local src = am:tracksTakes(0)[1]
      h.reaper.MIDI_SetAllEvts(src.take, 'EVTS-BLOB')
      local slotIdx, copy = am:duplicateUnpooledBelow(src)
      t.truthy(copy, 'copy returned')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      local below
      for _, tk in ipairs(takes) do if tk.startQN == 4 then below = tk end end
      t.truthy(below, 'copy lands at the append point')
      t.eq(below.slotIdx ~= src.slotIdx, true, 'fresh slot — not pooled with the source')
      t.eq(below.slotIdx, slotIdx, 'the slot it landed in comes back with the take')
      t.eq(below.name, 'lead', 'inherits the source name')
      local _, blob = h.reaper.MIDI_GetAllEvts(copy, '')
      t.eq(blob, 'EVTS-BLOB', 'MIDI events copied to the new take')
    end,
  },

  {
    -- The fix for "parking desyncs notes from their metadata": an unpooled clone
    -- mints a fresh pool, so eventMeta:copyPool must fork the source's metadata.
    name = 'duplicateUnpooledBelow forks the source per-event metadata onto the fresh pool',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local src = am:tracksTakes(0)[1]
      t.seedMeta(src.take, 1, { detune = -50 })       -- author metadata on the source pool
      local _, copy = am:duplicateUnpooledBelow(src)
      t.truthy(copy, 'copy returned')
      t.eq(t.loadMeta(copy)[1].detune, -50, 'the fresh pool inherited the source metadata')
    end,
  },

  {
    name = 'duplicateUnpooledBelow parks the clone for want of room',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      local src = am:tracksTakes(0)[1]
      h.reaper.MIDI_SetAllEvts(src.take, 'EVTS-BLOB')
      local slotIdx, parked = am:duplicateUnpooledBelow(src)
      t.truthy(slotIdx, 'a slot is minted even with nowhere to place it')
      t.eq(am:isParkedTake(parked), true, 'the clone hosts on scratch')
      t.eq(#am:tracksTakes(0), 2, 'nothing added to the grid')
      t.eq(am:takeForSlot(0, slotIdx), parked, 'the new slot resolves to the parked take')
      local _, blob = h.reaper.MIDI_GetAllEvts(parked, '')
      t.eq(blob, 'EVTS-BLOB', 'the parked clone carries the source events')
      t.eq(h.reaper.GetTakeName(parked), 'lead', 'and the source name')
    end,
  },

  {
    name = 'duplicateUnpooledBelow refuses on audio',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'audio', pos = 0, len = 4, srcFile = '/a.wav' } } },
      })
      t.eq(am:duplicateUnpooledBelow(am:tracksTakes(0)[1]), nil, 'audio refused silently')
      t.eq(#am:trackSlots(0), 1, 'and no slot minted')
    end,
  },

  {
    name = 'newTakeBelow creates an empty MIDI take of the asked-for length at the append point',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local src = am:tracksTakes(0)[1]
      h.reaper.MIDI_SetAllEvts(src.take, 'EVTS-BLOB')
      local slotIdx, fresh = am:newTakeBelow(src, 'verse', 2)
      t.truthy(fresh, 'fresh take returned')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      local below
      for _, tk in ipairs(takes) do if tk.startQN == 4 then below = tk end end
      t.truthy(below, 'fresh take lands at the append point')
      t.eq(below.slotIdx ~= src.slotIdx, true, 'separate slot')
      t.eq(below.slotIdx, slotIdx, 'the slot it landed in comes back with the take')
      t.eq(below.name, 'verse', 'named by the caller')
      t.eq(below.lengthQN, 2, 'as long as the caller asked, not as long as its source')
      local _, blob = h.reaper.MIDI_GetAllEvts(fresh, '')
      t.eq(blob, '', 'no events copied across')
    end,
  },

  {
    name = 'newTakeBelow parks the take for want of room',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      local slotIdx, parked = am:newTakeBelow(am:tracksTakes(0)[1], 'verse', 4)
      t.truthy(slotIdx, 'a slot is minted even with nowhere to place it')
      t.eq(am:isParkedTake(parked), true, 'the empty take hosts on scratch')
      t.eq(#am:tracksTakes(0), 2, 'nothing added to the grid')
      t.eq(am:takeForSlot(0, slotIdx), parked, 'the new slot resolves to the parked take')
    end,
  },

  {
    name = 'newTakeBelow measures the room against the length asked for',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 8, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      -- The gap below is 4 QN: the source's own length would fit, the asked-for 8 does not.
      local _, parked = am:newTakeBelow(am:tracksTakes(0)[1], 'verse', 8)
      t.eq(am:isParkedTake(parked), true, 'the take parks, the palette still grows')
      t.eq(#am:tracksTakes(0), 2, 'nothing added to the grid')
    end,
  },

  {
    name = 'newTakeBelow refuses on audio',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'audio', pos = 0, len = 4, srcFile = '/a.wav' } } },
      })
      t.eq(am:newTakeBelow(am:tracksTakes(0)[1], '', 4), nil, 'audio refused silently')
      t.eq(#am:trackSlots(0), 1, 'and no slot minted')
    end,
  },

  -- Palette colour (project-wide, keyed by takeId)
  {
    name = 'distinct pool guids on different tracks get distinct colourIdx',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' } } },
        { items = { { kind = 'midi', poolGuid = '{p2}' } } },
      })
      local a = am:tracksTakes(0)[1]
      local b = am:tracksTakes(1)[1]
      t.truthy(a.colourIdx ~= nil and b.colourIdx ~= nil, 'both takes get a colourIdx')
      t.truthy(a.colourIdx ~= b.colourIdx,
               'cross-track ids do not collide on colour: lowest-free is project-wide')
      t.eq(a.colourIdx + b.colourIdx, 1, 'two distinct ids consume indices 0 and 1')
    end,
  },

  {
    name = 'pooled instances on different tracks share one colourIdx',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}' } } },
        { items = { { kind = 'midi', poolGuid = '{p1}' } } },
      })
      local a = am:tracksTakes(0)[1]
      local b = am:tracksTakes(1)[1]
      t.eq(a.colourIdx, b.colourIdx, 'same pool id resolves to one colourIdx project-wide')
    end,
  },

  {
    name = 'createAndDropMidi stamps I_CUSTOMCOLOR on the new take',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local _, take = am:createAndDropMidi(0, 0, 1, 'lead')
      local stamped = h.reaper.GetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR')
      t.truthy(stamped ~= 0, 'fresh take carries the minted REAPER stamp')
      t.truthy(stamped & 0x1000000 ~= 0, 'active-flag bit is set so REAPER honours the colour')
    end,
  },

  {
    name = 'duplicateUnpooledBelow strips the source colour and mints a fresh one',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' } } },
      })
      local src = am:tracksTakes(0)[1]
      local srcStamp = h.reaper.GetMediaItemTakeInfo_Value(src.take, 'I_CUSTOMCOLOR')
      local _, copy = am:duplicateUnpooledBelow(src)
      t.truthy(copy, 'clone returned')
      local copyStamp = h.reaper.GetMediaItemTakeInfo_Value(copy, 'I_CUSTOMCOLOR')
      t.truthy(copyStamp ~= 0, 'clone carries its own stamp')
      t.truthy(copyStamp ~= srcStamp,
               'fresh pool identity gets a separate colour, not the source\'s')
      t.eq(h.reaper.GetMediaItemTakeInfo_Value(src.take, 'I_CUSTOMCOLOR'), srcStamp,
           'source stamp untouched: rePool clears the new item only')
    end,
  },

  {
    name = 'placement does not overwrite a pre-existing take colour (preserve override)',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, { { items = {} } })
      local slot, take = am:createAndDropMidi(0, 0, 1, 'lead')
      -- Simulate a user recolouring the take in REAPER after creation.
      h.reaper.SetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR', 0xDEADBE | 0x1000000)
      -- A dropInstance triggers ensureColours + stampForTake for the new
      -- instance only; the override take must be left alone.
      am:dropInstance(0, slot, 4, 1)
      t.eq(h.reaper.GetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR'), 0xDEADBE | 0x1000000,
           'override survives -- stampColour only writes when current value is 0')
    end,
  },

  -- takeId memo: REAPER recycles a freed take's pointer
  {
    name = 'a recycled take handle reports the new item\'s pool, not the dead take\'s',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', poolGuid = '{p1}', pos = 0, len = 4 },
                    { kind = 'midi', poolGuid = '{p1}', pos = 4, len = 4 },
                    { kind = 'midi', poolGuid = '{p2}', pos = 8, len = 4 } } },
      })
      local function takeAt(qn)
        for _, tk in ipairs(am:tracksTakes(0)) do
          if tk.startQN == qn then return tk end
        end
      end
      local p2 = takeAt(8)
      am:deleteTake(takeAt(4))            -- warms the memo, then frees tr1/take2

      -- REAPER hands the freed pointer back for a fresh {p2} instance.
      h.reaper:addItem('tr1', { take = 'tr1/take2', isMidi = true,
                                pos = 12, len = 4, poolGuid = '{p2}' })

      local recycled = takeAt(12)
      t.eq(recycled.slotIdx, p2.slotIdx, 'identity follows the item, not the recycled pointer')
      t.eq(recycled.colourIdx, p2.colourIdx, 'and so does the colour')
    end,
  },

}
