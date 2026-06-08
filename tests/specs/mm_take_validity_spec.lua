-- Integration spec: real midiManager + fakeReaper. Pins the dead-take
-- self-heal: when a bound take is deleted in REAPER (ValidatePtr2 -> false),
-- mm treats it as absent instead of dereferencing the dangling pointer.
-- Without this, the dormant "keep last frame" seam (bindTake(nil) leaves the
-- old take in mm) crashes the next configChanged-driven tm:rebuild via
-- mm:length -> GetMediaItemTake_Source on a dead take.

local t = require('support')

local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-validity'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  fakeReaper:seedMidi(take, { ccs = {}, texts = {} })
  return take, fakeReaper
end

local function killTake(fakeReaper, take)
  local realValidate = fakeReaper.ValidatePtr2
  fakeReaper.ValidatePtr2 = function(proj, ptr, ctype)
    if ctype == 'MediaItem_Take*' and ptr == take then return false end
    return realValidate(proj, ptr, ctype)
  end
end

return {
  {
    name = 'a deleted take reads as absent; deref accessors return nil, not a crash',
    run = function()
      local take, fakeReaper = freshTake()
      local mm = realMM(nil)
      mm:load(take)
      t.eq(mm:take(), take, 'baseline: live take is bound')

      killTake(fakeReaper, take)

      t.eq(mm:take(),       nil, 'dead take reads as nil')
      t.eq(mm:length(),     nil, 'length bails on a dead take')
      t.eq(mm:resolution(), nil, 'resolution bails on a dead take')
      t.eq(mm:name(),       nil, 'name bails on a dead take')
    end,
  },
}
