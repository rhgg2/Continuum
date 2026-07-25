-- Pins the stable-slot model: a loc is a slot id that lives as long as its event, so a value
-- assign, a ppq move and an add all leave every existing event's slot exactly where it was.
-- Walk order is ppq order (the order arrays), which after a move is no longer slot order.
-- A delete hands its slot back, and the next add reuses it before minting a fresh one.

local t = require('support')

local function noteField(mm, field)
  local out = {}
  for _, n in mm:notesRaw() do out[#out + 1] = n[field] end
  return out
end

-- uuid -> slot for every live note: the mapping stable slots promise not to churn.
local function slotByUuid(mm)
  local out = {}
  for loc, n in mm:notesRaw() do out[n.uuid] = loc end
  return out
end

local function pair(harness)
  return harness.bareMM{ notes = {
    { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
    { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
  } }
end

local function uuidAtPpq(mm, ppq)
  for _, n in mm:notesRaw() do if n.ppq == ppq then return n.uuid end end
end

return {
  {
    name = 'a value-only assign leaves every slot where it was',
    run = function(harness)
      local mm    = pair(harness)
      local tok   = uuidAtPpq(mm, 0)
      local slots = slotByUuid(mm)

      local same
      mm:modify(function() same = mm:assign(tok, { pitch = 65, vel = 90 }) end)
      t.eq(same, tok, 'identity is stable across a pitch change')

      local resolved
      mm:modify(function() resolved = mm:assign(tok, { vel = 80 }) end)
      t.truthy(resolved, 'the handle still resolves')

      t.deepEq(slotByUuid(mm), slots, 'no slot renumbered: nothing reindexed behind the verbs')
      t.deepEq(noteField(mm, 'ppq'),   { 0, 240 },  'order stands: nothing moved')
      t.deepEq(noteField(mm, 'pitch'), { 65, 62 },  'the assign landed')
      t.deepEq(noteField(mm, 'vel'),   { 80, 100 }, 'and so did the second')
    end,
  },

  {
    name = 'a ppq move re-splices the walk order and keeps both slots',
    run = function(harness)
      local mm    = pair(harness)
      local tok   = uuidAtPpq(mm, 0)
      local slots = slotByUuid(mm)
      mm:modify(function() mm:assign(tok, { ppq = 480, endppq = 720 }) end)

      t.deepEq(noteField(mm, 'ppq'),   { 240, 480 }, 'the moved note walks behind its neighbour')
      t.deepEq(noteField(mm, 'pitch'), { 62, 60 },   'and it is the moved note that is now last')
      t.deepEq(slotByUuid(mm), slots, 'the move renumbered nothing')
      t.deepEq(noteField(mm, 'loc'), { 2, 1 }, 'so the walk yields the slots out of order, as it must')
    end,
  },

  {
    name = 'an add mints past the high-water mark; a delete hands the slot back for reuse',
    run = function(harness)
      local mm    = pair(harness)
      local slots = slotByUuid(mm)
      mm:modify(function()
        mm:add{ evType = 'note', ppq = 120, endppq = 240, chan = 1, pitch = 61, vel = 100 }
      end)
      t.deepEq(noteField(mm, 'ppq'), { 0, 120, 240 }, 'the added note walks in its ppq place')
      t.deepEq(noteField(mm, 'loc'), { 1, 3, 2 },     'holding the freshly minted slot 3')
      for uuid, slot in pairs(slots) do
        t.eq(slotByUuid(mm)[uuid], slot, 'slot ' .. slot .. ' survived the add')
      end

      mm:modify(function() mm:delete(uuidAtPpq(mm, 120)) end)
      t.deepEq(noteField(mm, 'ppq'), { 0, 240 }, 'the survivors still walk in order')
      t.deepEq(noteField(mm, 'loc'), { 1, 2 },   'and their slots are untouched')

      mm:modify(function()
        mm:add{ evType = 'note', ppq = 60, endppq = 90, chan = 1, pitch = 63, vel = 100 }
      end)
      t.deepEq(noteField(mm, 'loc'), { 1, 3, 2 }, 'the freed slot 3 is reused, not a minted 4')
    end,
  },
}
