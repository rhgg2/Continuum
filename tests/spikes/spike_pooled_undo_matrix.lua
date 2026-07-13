-- spike_pooled_undo_matrix.lua — pooled-undo capture matrix, plain REAPER.
--
-- Setup: a project where track 1 and track 2 each hold one member of a
-- pooled MIDI pair, member on track 1 has a note 0. Run as a REAPER
-- action. One run per REAPER session per provenance (fresh / reloaded):
-- capture state is session-sticky, so save+reload between runs.
--
-- Prints, to the console: per gesture whether its undo point minted,
-- then an undo walk with restored velocity vs expected.

local N_GESTURES = 4
local EDIT_TRACK = 0           -- 0-based track index of the edited member
local ok, csv = reaper.GetUserInputs('pooled-undo matrix', 1,
  'read after g1 (none/false/true):', 'none')
if not ok then return end
local READ_AFTER_G1 = ({ none = 'none', ['false'] = 'read-false', ['true'] = 'read-true' })[csv]
if not READ_AFTER_G1 then return reaper.ShowConsoleMsg('bad choice: ' .. csv .. '\n') end

local function log(s) reaper.ShowConsoleMsg(s .. '\n') end

local function member()
  local tr = reaper.GetTrack(0, EDIT_TRACK)
  local it = tr and reaper.GetTrackMediaItem(tr, 0)
  return tr, it, it and reaper.GetActiveTake(it)
end

local function vel()
  local _, _, tk = member()
  if not tk then return 'no-take' end
  return select(8, reaper.MIDI_GetNote(tk, 0))
end

local function gesture(v, label)
  local tr, it, tk = member()
  reaper.Undo_BeginBlock()
  reaper.MIDI_SetNote(tk, 0, nil, nil, nil, nil, nil, nil, v, false)
  reaper.MarkTrackItemsDirty(tr, it)
  reaper.Undo_EndBlock(label, -1)
end

local expected, step = {}, 0
log(('=== config: N_GESTURES=%d READ_AFTER_G1=%s EDIT_TRACK=%d ==='):format(
  N_GESTURES, READ_AFTER_G1, EDIT_TRACK))
local function tick()
  step = step + 1
  -- points finalise at cycle end: the top of cycle k+1 is where gesture
  -- k's mint status becomes trustworthy
  if step > 1 then
    local top = tostring(reaper.Undo_CanUndo2(0))
    local want = 'g' .. (step - 1)
    log(('  g%d %s (canUndo=%s)'):format(step - 1, top == want and 'MINTED' or 'NO POINT', top))
  end
  if step <= N_GESTURES then
    local v = 10 * step
    gesture(v, 'g' .. step)
    expected[step] = v
    log(('g%d: set vel=%d'):format(step, v))
    if step == 1 and READ_AFTER_G1 ~= 'none' then
      local _, it = member()
      reaper.GetItemStateChunk(it, '', READ_AFTER_G1 == 'read-true')
      log('  [chunk read injected, isundo=' .. tostring(READ_AFTER_G1 == 'read-true') .. ']')
    end
    reaper.defer(tick)
  else
    log('undo walk:')
    local walk = 0
    while walk < N_GESTURES do
      local top = tostring(reaper.Undo_CanUndo2(0))
      local gk = top:match('^g(%d+)$')
      if not gk then break end
      reaper.Undo_DoUndo2(0)
      walk = walk + 1
      local want = expected[tonumber(gk) - 1] or 'pre-g1 value'
      local got = vel()
      log(('  undo %d popped %s: vel=%s, expected %s — %s'):format(
        walk, top, tostring(got), tostring(want),
        got == want and 'RESTORED' or 'NO-OP/WRONG'))
    end
    log('done; canUndo=' .. tostring(reaper.Undo_CanUndo2(0)))
  end
end
tick()
