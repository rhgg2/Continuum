-- keyDispatch: the prefix-capture + keychain walk extracted from coordinator
-- (design/fx-patterns.md P3 step a). Now an importable module the fx-pattern
-- mini modal reuses, so pin the dispatch contract directly: first-hit claiming,
-- the acceptCmds gate, prefix capture + finish, false-declines, and the
-- pageSuppressed root narrowing.
--
-- The dispatcher is handed a real keyQueue, filled from the same fake ImGui each
-- time a test sets the key state (see docs/keyQueue.md). Every reader in it takes
-- what it acts on, so the queue after the pass is the observable throughout: a
-- press something fired on is gone, one nothing acted on is still there, and a
-- declined one is back -- and which of them dispatch may claim at all while one of
-- the four owners holds the frame.

local t    = require('support')
local util = require('util')

-- Controllable fake ImGui: a test sets which keys are pressed/held + the mod
-- mask, then reads back what the walk did.
local fakeImGui = { Mod_None = 0, Mod_Ctrl = 1, Mod_Super = 2, Mod_Shift = 4, Mod_Alt = 8,
                    Key_Slash = 200, Key_Escape = 201,
                    Key_A = 300, Key_B = 301, Key_C = 302, Key_D = 303, Key_E = 304 }
for d = 0, 9 do fakeImGui['Key_' .. d] = 100 + d end

local pressed, down, curMods = {}, {}, 0
-- A pressed key answers both readings of IsKeyPressed, so the fill reads it as a fresh strike.
function fakeImGui.GetKeyMods(_)      return curMods            end
function fakeImGui.IsKeyPressed(_, k) return pressed[k] == true end
function fakeImGui.IsKeyDown(_, k)    return down[k]    == true end

local ctx = {}
local kq          -- the frame's queue, rebuilt per loadKD and refilled per setKeys

-- A pressed key is also down; `down` alone models a hold with no fresh press. `owner`
-- names one of the four keyboard owners the fill records, or nobody.
local function setKeys(opts)
  pressed, down, curMods = {}, {}, opts.mods or 0
  for _, k in ipairs(opts.pressed or {}) do pressed[k] = true; down[k] = true end
  for _, k in ipairs(opts.down    or {}) do down[k] = true end
  kq:fill(opts.owner)
end

_G.reaper.ImGui_GetBuiltinPath = _G.reaper.ImGui_GetBuiltinPath or function() return '/stub' end

-- Rebind imgui to ours before loading keyDispatch: earlier specs' module-load
-- preloads cache a different fake, so nil both and re-require (curveEditor idiom).
-- keyQueue enumerates the shim it finds, so instantiate it under the same rebind.
local function loadKD()
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  package.loaded['imgui']       = nil
  package.loaded['keyDispatch'] = nil
  local kd = require('keyDispatch')
  kq = util.instantiate('keyQueue', { ctx = ctx })
  return kd
end

-- Fresh real cmgr with commands bound to bare (Mod_None) keys; the returned log
-- records which bodies ran and the last prefix arg one received.
local function freshCmgr()
  local cmgr = util.instantiate('commandManager', { cm = nil })
  local log  = { fired = {}, arg = nil }
  cmgr:registerAll{
    alpha   = function()  log.fired[#log.fired + 1] = 'alpha'   end,
    beta    = function()  log.fired[#log.fired + 1] = 'beta'    end,
    counted = function(n) log.fired[#log.fired + 1] = 'counted'; log.arg = n end,
    decline = function()  log.fired[#log.fired + 1] = 'decline'; return false end,
  }
  cmgr:bind('alpha',   { fakeImGui.Key_A })
  cmgr:bind('beta',    { fakeImGui.Key_B })
  cmgr:bind('counted', { fakeImGui.Key_C })
  cmgr:bind('decline', { fakeImGui.Key_D })
  return cmgr, log
end

return {
  {
    -- The lotus menu's letters: while the top scope declares a letter sink, a bare letter
    -- goes to it and never reaches the keychain, whether or not the sink does anything
    -- with it. Shift is tolerated, since the menu draws its letters uppercase; any other
    -- modifier is a chord, and dispatches as one.
    name = 'a scope capturing letters takes them ahead of the keychain walk',
    run = function()
      local cmgr, log = freshCmgr()
      local kd, seen  = loadKD(), {}
      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'alpha' }, 'with no sink on the stack the letter is an ordinary binding')

      cmgr:scope('walk').captureLetter = function(letter) util.add(seen, letter) end
      cmgr:push('walk')
      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(seen, { 'A' }, 'the captured letter reaches the sink as a letter')
      t.deepEq(log.fired, { 'alpha' }, 'while the command it binds stays unfired')

      setKeys{ pressed = { fakeImGui.Key_B }, mods = fakeImGui.Mod_Shift }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(seen, { 'A', 'B' }, 'Shift is tolerated')

      setKeys{ pressed = { fakeImGui.Key_B }, mods = fakeImGui.Mod_Ctrl }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(seen, { 'A', 'B' }, 'and a chord is no menu letter')
    end,
  },

  {
    -- A leaf's letter closes the walk inside the capture, so by the time the grid's own
    -- key pass runs, the sink it gates on is gone while the letter is still pressed. The
    -- capture claimed the press, which is what keeps note entry off it.
    name = 'a captured letter leaves the queue, so the same frame\'s note entry cannot see it',
    run = function()
      local cmgr, log = freshCmgr()
      local kd   = loadKD()
      local walk = cmgr:scope('walk')
      walk.captureLetter = function() cmgr:pop(walk) end   -- a leaf: closes, then invokes
      cmgr:push(walk)

      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.eq(kq:take(fakeImGui.Key_A), nil, 'the letter the walk took is gone from the queue')
      t.eq(cmgr:letterCapture(), nil, 'though the sink the grid gates on is already gone')
      t.deepEq(log.fired, {}, 'and the binding the letter carries never fires')
    end,
  },

  {
    -- The slash lives two lives: the rational's bar and the menu key. With a prefix open
    -- it leads both, and the key after it says which was meant. A digit continues the
    -- rational and dismisses the walk the slash opened, through the dismissal its scope
    -- declares beside the letter sink.
    name = 'a slash during prefix entry appends and opens the walk; a digit takes it back',
    run = function()
      local cmgr, log = freshCmgr()
      local kd, dismissed = loadKD(), 0
      local walk = cmgr:scope('walk')
      walk.captureLetter = function() end
      walk.dismiss       = function() dismissed = dismissed + 1; cmgr:pop(walk) end
      cmgr:registerAll{ openMenu = function() util.add(log.fired, 'openMenu'); cmgr:push(walk) end }

      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_3 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.eq(dismissed, 0, 'a digit with no walk up dismisses nothing')

      setKeys{ pressed = { fakeImGui.Key_Slash } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.eq(kq:take(fakeImGui.Key_Slash), nil, 'prefix capture claimed the slash')
      t.deepEq(log.fired, { 'openMenu' }, 'and it opened the walk on its way through')
      t.eq(cmgr:isPrefixActive(), true, 'while the buffer stays open')

      setKeys{ pressed = { fakeImGui.Key_2 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.eq(dismissed, 1, 'the digit resolves the slash as a bar, and dismisses the walk')
      t.eq(cmgr:finishPrefix(), 1.5, 'leaving the rational the two digits typed')
    end,
  },

  {
    -- The other reading: a letter after the slash is a menu letter, and goes to the sink
    -- with the buffer untouched. The walk freezes nothing, so the prefix is still pending
    -- when the leaf it reaches invokes.
    name = 'a letter after the slash walks, and leaves the prefix for the leaf to freeze',
    run = function()
      local cmgr, log = freshCmgr()
      local kd, seen  = loadKD(), {}
      local walk = cmgr:scope('walk')
      walk.captureLetter = function(letter) util.add(seen, letter) end
      cmgr:registerAll{ openMenu = function() cmgr:push(walk) end }

      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_4 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      setKeys{ pressed = { fakeImGui.Key_Slash } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)

      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(seen, { 'A' }, 'the letter reaches the sink')
      t.deepEq(log.fired, {}, 'never the binding it would otherwise fire')
      t.eq(cmgr:isPrefixActive(), true, 'the walk leaves the buffer unfrozen')
      t.eq(cmgr:finishPrefix(), 4, 'holding the numerator the leaf will take')
    end,
  },

  {
    name = 'a pressed bound key fires its command and is claimed',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'alpha' }, "only the pressed key's command fires")
      t.eq(kq:take(fakeImGui.Key_A), nil, 'and the walk claimed the press it acted on')
    end,
  },

  {
    -- The claim precedes what the press sets in motion. A command raising a modal or a
    -- picker draws it in the same frame, so the queue that reader inherits must already
    -- be short the press that raised it; the body below reads the queue as it would.
    name = 'the press is claimed before the command it selects runs',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      local insideWalk = 'unset'
      cmgr:registerAll{ raise = function()
        insideWalk = kq:take(fakeImGui.Key_E)
        util.add(log.fired, 'raise')
      end }
      cmgr:bind('raise', { fakeImGui.Key_E })

      setKeys{ pressed = { fakeImGui.Key_E } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'raise' }, 'the bound command ran')
      t.eq(insideWalk, nil, 'and the queue it inherits no longer holds the press that selected it')
    end,
  },

  {
    name = 'acceptCmds=false short-circuits: nothing dispatched',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = false }, cmgr, kq)
      t.deepEq(log.fired, {}, 'no command runs while suppressed')
      t.truthy(kq:take(fakeImGui.Key_A), 'and the press is left in the queue for a later reader')
    end,
  },

  {
    -- A key's state is not a press: the fill stocks the queue from presses alone, so a key
    -- merely held down puts nothing in it and the walk finds nothing to act on.
    name = 'a held (not freshly pressed) bound key does not fire',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ down = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, {}, 'no command fired on a mere hold')
      t.eq(kq:takeAny(), nil, 'and the hold stocked the queue with nothing')
    end,
  },

  {
    name = 'a digit while a prefix is open is captured, not dispatched',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_5 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.eq(kq:take(fakeImGui.Key_5), nil, 'prefix capture claimed the digit')
      t.eq(cmgr:isPrefixActive(), true, 'prefix stays open across a digit')
      t.deepEq(log.fired, {}, 'no command dispatched while accumulating')
    end,
  },

  {
    name = 'with a prefix open, a bound key freezes the prefix, dispatches, and clears it',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_5 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)   -- accumulate '5'
      setKeys{ pressed = { fakeImGui.Key_C } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'counted' }, 'the prefixed command fired once, through the frozen prefix')
      t.eq(cmgr:isPrefixActive(), false, 'prefix state cleared after the prefixed invoke')
    end,
  },

  {
    -- The walk claims before it invokes, so a decline has to hand the entry back: it returns
    -- to the head of the queue, for a later keymap binding the same key, or for the readers
    -- after the walk.
    name = 'a command returning false declines, and its press goes back in the queue',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_D, fakeImGui.Key_E } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'decline' }, 'the body still ran')
      local first = kq:takeAny()
      t.eq(first and first.key, fakeImGui.Key_D,
           'and its press is back at the head, ahead of the frame\'s other presses')
    end,
  },

  {
    name = 'pageSuppressed narrows the walk to root: page bindings die, globals live',
    run = function()
      local cmgr, log = freshCmgr()
      local page = cmgr:scope('page')
      page:register('pageOnly', function() log.fired[#log.fired + 1] = 'pageOnly' end)
      page:bind('pageOnly', { fakeImGui.Key_E })
      cmgr:push(page)
      local kd = loadKD()

      setKeys{ pressed = { fakeImGui.Key_E } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'pageOnly' }, 'page command fired without suppression')

      log.fired = {}
      setKeys{ pressed = { fakeImGui.Key_E } }
      kd.dispatchKeys({ acceptCmds = true, pageSuppressed = true }, cmgr, kq)
      t.deepEq(log.fired, {}, 'the page binding is invisible when page-suppressed')
      t.truthy(kq:take(fakeImGui.Key_E), 'and the press it would have taken stays in the queue')
      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true, pageSuppressed = true }, cmgr, kq)
      t.deepEq(log.fired, { 'alpha' }, 'global binding still fires under pageSuppressed')
    end,
  },

  {
    name = 'a shift-chord binding fires under shift',
    run = function()
      local cmgr, log = freshCmgr()
      cmgr:registerAll{ gamma = function() log.fired[#log.fired + 1] = 'gamma' end }
      cmgr:bind('gamma', { { fakeImGui.Key_9, fakeImGui.Mod_Shift } })
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_9 }, mods = fakeImGui.Mod_Shift }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, { 'gamma' }, 'chord command fired')
      t.eq(kq:take(fakeImGui.Key_9, fakeImGui.Mod_Shift), nil, 'and the press is claimed at the chord mask')
    end,
  },

  {
    name = 'the same key pressed bare ignores the shift binding entirely',
    run = function()
      local cmgr, log = freshCmgr()
      cmgr:registerAll{ gamma = function() log.fired[#log.fired + 1] = 'gamma' end }
      cmgr:bind('gamma', { { fakeImGui.Key_9, fakeImGui.Mod_Shift } })
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_9 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(log.fired, {}, 'no command fired')
      t.truthy(kq:take(fakeImGui.Key_9), 'and the bare press the chord does not match stays in the queue')
    end,
  },

  {
    -- A capture is a claim, so the digit the prefix buffer took is gone from the queue and no
    -- later reader on the frame can act on it twice. The unbound letter pressed alongside it
    -- stays, and stands as the evidence that the fill stocked the queue with both.
    name = 'a captured digit leaves the queue; the press nothing claimed stays in it',
    run = function()
      local cmgr = freshCmgr()
      local kd = loadKD()
      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_5, fakeImGui.Key_E } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.truthy(kq:take(fakeImGui.Key_E), 'the fill stocked the frame with both presses')
      t.eq(kq:take(fakeImGui.Key_5), nil, 'and prefix capture claimed the digit')
    end,
  },

  {
    -- The letter sink claims the same way, at the frame's exact mask: a Shift-letter is the
    -- menu's too, and the entry it takes carries Shift.
    name = 'a captured letter leaves the queue, at the mask it was struck with',
    run = function()
      local cmgr = freshCmgr()
      local kd, seen = loadKD(), {}
      cmgr:scope('walk').captureLetter = function(letter) util.add(seen, letter) end
      cmgr:push('walk')

      setKeys{ pressed = { fakeImGui.Key_A }, mods = fakeImGui.Mod_Shift }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.deepEq(seen, { 'A' }, 'the sink got the letter')
      t.eq(kq:take(fakeImGui.Key_A, fakeImGui.Mod_Shift), nil, 'and the press it acted on is gone')
    end,
  },

  {
    -- Ownership is settled at the fill, and a dispatch speaking for nobody claims nothing while
    -- one of the four holds the frame. The mini pattern editor runs inside the modal the fill
    -- recorded, and says so through state.claimant.
    name = 'under an owner, only the dispatch claiming that name captures',
    run = function()
      local cmgr = freshCmgr()
      local kd = loadKD()
      cmgr:beginPrefix()

      setKeys{ pressed = { fakeImGui.Key_7 }, owner = 'modal' }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, kq)
      t.truthy(kq:take(fakeImGui.Key_7, nil, 'modal'), 'an unnamed dispatch leaves the owned queue alone')

      setKeys{ pressed = { fakeImGui.Key_7 }, owner = 'modal' }
      kd.dispatchKeys({ acceptCmds = true, claimant = 'modal' }, cmgr, kq)
      t.eq(cmgr:finishPrefix(), 7, 'the dispatch claiming the modal captures, and only its digit reached the buffer')
    end,
  },
}
