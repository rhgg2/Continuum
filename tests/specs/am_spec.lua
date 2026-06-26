-- arrangeManager: discovery, slot auto-allocation, placement, reswing.

local t = require('support')
local util = require('util')
local scratch = require('scratch')

local function mkAm(harness, opts)
  local h = harness.mk(opts)
  local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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

  --------------------------------------------------------------------
  -- Per-take edits
  --------------------------------------------------------------------
  --------------------------------------------------------------------
  -- Natural length + relayout
  --------------------------------------------------------------------
  {
    name = 'tracksTakes reports naturalLenQN; default is util.OPEN → source length',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 2, srcLen = 6, poolGuid = '{p1}' } } },
      })
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.naturalLenQN, 6, 'default natural = source length')
      t.eq(tk.lengthQN,     2, 'rendered stays at the seeded item length until relayout reads source')
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
      t.eq(scratch.peek(), nil, 'nothing parked — no scratch track minted')
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
    name = 'mintParkedTake shows the new slot at once; isParkedTake flags scratch-hosted takes',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local live = am:tracksTakes(0)[1].take
      local slot = am:mintParkedTake(0, 'fresh', 4)
      t.truthy(slot, 'a parked slot was minted')
      t.eq(#am:trackSlots(0), 2, 'the new slot is visible immediately — cache invalidated on mint')
      local parked = am:takeForSlot(0, slot)
      t.truthy(parked, 'the parked take resolves through its slot')
      t.eq(am:isParkedTake(parked), true, 'minted take hosts on scratch — parked')
      t.eq(am:isParkedTake(live),   false, 'a live grid take is not parked')
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
      local h, am = mkAm(harness)
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
  -- Below-trio: duplicateBelow / duplicateUnpooledBelow / newTakeBelow
  --------------------------------------------------------------------
  {
    name = 'duplicateBelow places a pooled clone at startQN + naturalLenQN',
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
      t.truthy(below, 'second take lands at the natural end of the first')
      t.eq(below.slotIdx, src.slotIdx, 'pooled — same slot as the source')
      t.eq(below.name,    'lead',       'pooled clone keeps the source name')
    end,
  },

  {
    name = 'duplicateBelow lands past a truncating downstream neighbour',
    run = function(harness)
      local h, am = mkAm(harness)
      -- upstream natural=8, downstream at QN 4 → relayout truncates
      -- upstream's rendered to 4, but natural still 8.
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 8, srcLen = 8, poolGuid = '{p1}' },
                    { kind = 'midi', pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' } } },
      })
      am:moveTake(am:tracksTakes(0)[2], 0)    -- nudge relayout to truncate
      local src   = am:tracksTakes(0)[1]
      t.eq(src.lengthQN, 4, 'rendered is truncated')
      t.eq(src.naturalLenQN, 8, 'natural still 8')
      local clone = am:duplicateBelow(src)
      t.truthy(clone, 'truncation does not block the below-drop')
      local atEight
      for _, tk in ipairs(am:tracksTakes(0)) do if tk.startQN == 8 then atEight = tk end end
      t.truthy(atEight, 'clone lands at the natural end (QN 8), past the downstream neighbour')
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
      local copy = am:duplicateUnpooledBelow(src)
      t.truthy(copy, 'copy returned')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      local below
      for _, tk in ipairs(takes) do if tk.startQN == 4 then below = tk end end
      t.truthy(below, 'copy lands at natural end')
      t.eq(below.slotIdx ~= src.slotIdx, true, 'fresh slot — not pooled with the source')
      t.eq(below.name, 'lead', 'inherits the source name')
      local _, blob = h.reaper.MIDI_GetAllEvts(copy, '')
      t.eq(blob, 'EVTS-BLOB', 'MIDI events copied to the new take')
    end,
  },

  {
    name = 'duplicateUnpooledBelow refuses on collision and on audio',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi',  pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi',  pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' },
                    { kind = 'audio', pos = 16, len = 4, srcFile = '/a.wav' } } },
      })
      local takes = am:tracksTakes(0)
      t.eq(am:duplicateUnpooledBelow(takes[1]), nil, 'destination QN 4 collides')
      local audio
      for _, tk in ipairs(takes) do if tk.kind == 'audio' then audio = tk end end
      t.eq(am:duplicateUnpooledBelow(audio), nil, 'audio refused silently')
    end,
  },

  {
    name = 'newTakeBelow creates an empty MIDI take at natural end',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi', pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}', takeName = 'lead' } } },
      })
      local src = am:tracksTakes(0)[1]
      h.reaper.MIDI_SetAllEvts(src.take, 'EVTS-BLOB')
      local fresh = am:newTakeBelow(src)
      t.truthy(fresh, 'fresh take returned')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2)
      local below
      for _, tk in ipairs(takes) do if tk.startQN == 4 then below = tk end end
      t.truthy(below, 'fresh take lands at the natural end')
      t.eq(below.slotIdx ~= src.slotIdx, true, 'separate slot')
      t.eq(below.name, '', 'empty name — caller will rename via take-props')
      local _, blob = h.reaper.MIDI_GetAllEvts(fresh, '')
      t.eq(blob, '', 'no events copied across')
    end,
  },

  {
    name = 'newTakeBelow refuses on collision and on audio',
    run = function(harness)
      local h, am = mkAm(harness)
      seedTracks(h, {
        { items = { { kind = 'midi',  pos = 0, len = 4, srcLen = 4, poolGuid = '{p1}' },
                    { kind = 'midi',  pos = 4, len = 4, srcLen = 4, poolGuid = '{p2}' },
                    { kind = 'audio', pos = 16, len = 4, srcFile = '/a.wav' } } },
      })
      local takes = am:tracksTakes(0)
      t.eq(am:newTakeBelow(takes[1]), nil, 'destination QN 4 collides')
      local audio
      for _, tk in ipairs(takes) do if tk.kind == 'audio' then audio = tk end end
      t.eq(am:newTakeBelow(audio), nil, 'audio refused silently')
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
      local copy = am:duplicateUnpooledBelow(src)
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

}
