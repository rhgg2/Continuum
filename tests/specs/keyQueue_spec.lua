-- keyQueue holds one frame's key presses. The fill polls every key constant the ImGui shim
-- carries, less the mouse and the modifier keys, and a claim removes what it returns -- so a
-- press one reader acts on is gone for the next. These pin the enumeration and its cost (the
-- second call separating a fresh press from an autorepeat is paid only for a key that answered),
-- the exact modifier match with Mod_None standing in for an omitted mask, ownership declining
-- every claimant but the owner, and held/mods reading live state under an owner.
--
-- They also pin the fill's own claim: an unowned frame with an item active is a live text
-- field, which takes the keys a field consumes before any reader sees them.
--
-- The last case scans the production sources instead of driving the queue: modifier state is the
-- queue's to read, so keyQueue.lua is the only file that may name ImGui's GetKeyMods. Every
-- other reader, the mouse gestures included, goes through keyQueue:mods().

local t    = require('support')
local util = require('util')

local ctx = {}
local img = t.imgui()

-- The keys the fill drops, written onto the fake before keyQueue enumerates it so the
-- exclusions have something to exclude. The enumeration test reads this same list back.
local EXCLUDED = { 'MouseLeft', 'MouseRight', 'MouseWheelX', 'MouseWheelY',
                   'LeftCtrl',  'LeftShift',  'LeftAlt',     'LeftSuper',
                   'RightCtrl', 'RightShift', 'RightAlt',    'RightSuper' }
for i, name in ipairs(EXCLUDED) do img['Key_' .. name] = 900 + i end

-- Fake key state. pressed[key] is 'fresh' or 'repeat'; every IsKeyPressed call is logged, so a
-- test can assert what the fill asked for as well as what it made of the answers. itemActive is
-- ImGui's active item, which the fill reads as a live field.
local pressed, down, curMods, polled = {}, {}, 0, {}
local itemActive = false

function img.IsAnyItemActive() return itemActive      end
function img.GetKeyMods()      return curMods         end
function img.IsKeyDown(_, key) return down[key] == true end
function img.IsKeyPressed(_, key, withRepeat)
  util.add(polled, { key = key, withRepeat = withRepeat })
  if withRepeat then return pressed[key] ~= nil end
  return pressed[key] == 'fresh'
end

package.preload['imgui'] = function() return function() return img end end

local function newQueue()
  pressed, down, curMods, polled, itemActive = {}, {}, 0, {}, false
  return util.instantiate('keyQueue', { ctx = ctx })
end

local function nameOf(value)
  for name, v in pairs(img) do if v == value then return name end end
  return tostring(value)
end

-- The keys the fill asked about, and the keys it should have asked about.
local function polledKeys()
  local seen = {}
  for _, call in ipairs(polled) do if call.withRepeat then seen[call.key] = true end end
  return seen
end

local function shimKeys()
  local excluded = {}
  for _, name in ipairs(EXCLUDED) do excluded['Key_' .. name] = true end
  local want = {}
  for name, value in pairs(img) do
    if type(name) == 'string' and name:sub(1, 4) == 'Key_' and not excluded[name] then
      want[value] = name
    end
  end
  return want
end

return {
  {
    name = 'the fill polls every key constant on the shim, less the mouse and modifier keys',
    run = function()
      local q = newQueue()
      q:fill()
      local seen, want = polledKeys(), shimKeys()
      t.truthy(next(want), 'the fake shim carries key constants to enumerate')
      local missing, extra = {}, {}
      for value, name in pairs(want) do if not seen[value] then util.add(missing, name) end end
      for value in pairs(seen)        do if not want[value] then util.add(extra, nameOf(value)) end end
      t.deepEq(missing, {}, 'every key constant is polled')
      t.deepEq(extra,   {}, 'and nothing else is')
    end,
  },

  {
    name = 'a press queues an entry carrying the frame modifiers, and a claim removes it',
    run = function()
      local q = newQueue()
      pressed[img.Key_A] = 'fresh'
      q:fill()
      local entry = q:take(img.Key_A)
      t.truthy(entry, 'the press is in the queue')
      t.eq(entry.key,  img.Key_A,    'the entry names the key')
      t.eq(entry.mods, img.Mod_None, 'and carries the mask the fill read')
      t.falsy(entry.repeated,        'a first strike is no autorepeat')
      t.eq(q:take(img.Key_A), nil, 'the claim removed it')
      t.eq(q:takeAny(),       nil, 'so takeAny finds nothing either')
    end,
  },

  {
    name = "each fill replaces the last frame's entries",
    run = function()
      local q = newQueue()
      pressed[img.Key_A] = 'fresh'
      q:fill()
      pressed[img.Key_A] = nil
      q:fill()
      t.eq(q:take(img.Key_A), nil, 'a press nobody claimed does not outlive its frame')
    end,
  },

  {
    name = 'take matches the modifier mask exactly, an omitted mask meaning Mod_None',
    run = function()
      local q = newQueue()
      curMods = img.Mod_Ctrl
      pressed[img.Key_A] = 'fresh'
      q:fill()
      t.eq(q:take(img.Key_A), nil, 'a bare take declines a chord')
      t.eq(q:take(img.Key_A, img.Mod_Ctrl | img.Mod_Shift), nil, 'and a wider mask misses it')
      t.truthy(q:take(img.Key_A, img.Mod_Ctrl), 'the mask the fill read claims it')
    end,
  },

  {
    name = 'autorepeat rides on the entry, and only a key that answered costs the second call',
    run = function()
      local q = newQueue()
      pressed[img.Key_A] = 'repeat'
      pressed[img.Key_B] = 'fresh'
      q:fill()
      local a, b = q:take(img.Key_A), q:take(img.Key_B)
      t.truthy(a and b, 'both presses queued')
      t.truthy(a.repeated, 'a key held past the delay reads as repeated')
      t.falsy(b.repeated,  'a first strike does not')
      local separated = 0
      for _, call in ipairs(polled) do
        if call.withRepeat == false then separated = separated + 1 end
      end
      t.eq(separated, 2, 'the fresh/repeat question is asked once per pressed key')
    end,
  },

  {
    name = 'takeAny claims the queue in key order',
    run = function()
      local q = newQueue()
      pressed[img.Key_A], pressed[img.Key_B] = 'fresh', 'fresh'
      q:fill()
      local lo, hi = math.min(img.Key_A, img.Key_B), math.max(img.Key_A, img.Key_B)
      local first = q:takeAny()
      t.truthy(first, 'the queue holds both presses')
      t.eq(first.key,       lo,  'the lower key constant comes first')
      t.eq(q:takeAny().key, hi,  'then the higher')
      t.eq(q:takeAny(),     nil, 'and the queue is empty')
    end,
  },

  {
    -- A field takes the printables, the two erasing keys, and the caret's own; what it does
    -- not consume is its host's, and reaches the queue. The fill never asks after a key it
    -- would drop, so the dropped keys are absent from the poll log as well as from the queue.
    name = 'a live text field claims the keys it consumes, and leaves the rest',
    run = function()
      local q = newQueue()
      local taken   = { 'A', '5', 'Keypad3', 'Space', 'Minus', 'Backspace', 'Delete',
                        'LeftArrow', 'UpArrow', 'Home', 'End' }
      local survives = { 'Enter', 'KeypadEnter', 'Escape', 'Tab', 'F1', 'PageUp', 'Insert' }
      for _, name in ipairs(taken)    do pressed[img['Key_' .. name]] = 'fresh' end
      for _, name in ipairs(survives) do pressed[img['Key_' .. name]] = 'fresh' end
      itemActive = true
      q:fill()
      local seen = polledKeys()
      for _, name in ipairs(taken) do
        t.eq(q:take(img['Key_' .. name]), nil, name .. ' is the field\'s')
        t.falsy(seen[img['Key_' .. name]], 'and the fill did not ask after ' .. name)
      end
      for _, name in ipairs(survives) do
        t.truthy(q:take(img['Key_' .. name]), name .. ' is the field host\'s')
      end
    end,
  },

  {
    -- Ctrl and Super make a command chord, not a keystroke; Shift and Alt make a character,
    -- so a press under either is still the field's.
    name = 'a Ctrl or Super chord survives the field claim, a Shift one does not',
    run = function()
      for _, mod in ipairs{ 'Mod_Ctrl', 'Mod_Super' } do
        local q = newQueue()
        pressed[img.Key_A], curMods, itemActive = 'fresh', img[mod], true
        q:fill()
        t.truthy(q:take(img.Key_A, img[mod]), 'A under ' .. mod .. ' reaches the queue')
      end
      local q = newQueue()
      pressed[img.Key_A], curMods, itemActive = 'fresh', img.Mod_Shift, true
      q:fill()
      t.eq(q:take(img.Key_A, img.Mod_Shift), nil, 'a shifted printable is typing')
    end,
  },

  {
    -- An owner takes the whole keyboard, the field's keys with it: the picker's filter is a
    -- live field, and its arrows would otherwise be claimed out from under it.
    name = 'the field claim is off while an owner holds the frame',
    run = function()
      local q = newQueue()
      pressed[img.Key_LeftArrow], pressed[img.Key_A], itemActive = 'fresh', 'fresh', true
      q:fill('picker')
      t.truthy(q:take(img.Key_LeftArrow, nil, 'picker'), 'the owner still has its arrows')
      t.truthy(q:take(img.Key_A,         nil, 'picker'), 'and the printables too')
    end,
  },

  {
    name = 'an owned queue declines every claimant but the owner',
    run = function()
      local q = newQueue()
      pressed[img.Key_A] = 'fresh'
      q:fill('palette')
      t.eq(q:take(img.Key_A),               nil, 'an unnamed reader is declined')
      t.eq(q:takeAny(),                     nil, 'and so is a bare takeAny')
      t.eq(q:take(img.Key_A, nil, 'modal'),  nil, 'as is another owner')
      t.truthy(q:take(img.Key_A, nil, 'palette'), 'the owner claims it')
      t.falsy(pcall(function() q:fill('jazz') end),
              'an owner outside the five raises')
      t.falsy(pcall(function() q:take(img.Key_A, nil, 'jazz') end),
              'as does a claim made under one')
    end,
  },

  {
    name = 'held and mods read live state, whoever owns the queue',
    run = function()
      local q = newQueue()
      down[img.Key_A], curMods = true, img.Mod_Shift
      pressed[img.Key_A] = 'fresh'
      q:fill('modal')
      t.truthy(q:held(img.Key_A), 'a key that is down answers under an owner')
      t.falsy(q:held(img.Key_B),  'one that is not, does not')
      curMods = img.Mod_Alt
      t.eq(q:mods(), img.Mod_Alt, 'mods reads the mask now, not the one the fill stamped')
      local entry = q:take(img.Key_A, img.Mod_Shift, 'modal')
      t.truthy(entry, 'the entry is still there to claim')
      t.eq(entry.mods, img.Mod_Shift, 'and keeps the stamp the fill gave it')
    end,
  },

  {
    name = 'keyQueue is the only production file that names GetKeyMods',
    run = function()
      local specDir = debug.getinfo(1, 'S').source:match('^@?(.*)/[^/]+$')
      local listing = assert(io.popen('ls -1 ' .. specDir .. '/../../*.lua'))
      local named = {}
      local scanned = 0
      for path in listing:lines() do
        local file = assert(io.open(path, 'r'))
        local source = file:read('a'); file:close()
        scanned = scanned + 1
        if source:find('GetKeyMods', 1, true) then util.add(named, path:match('[^/]+$')) end
      end
      listing:close()
      t.truthy(scanned > 50, 'the scan found the production tree (' .. scanned .. ' files)')
      t.deepEq(named, { 'keyQueue.lua' },
        'these files read ImGui modifier state: ' .. table.concat(named, ' '))
    end,
  },
}
