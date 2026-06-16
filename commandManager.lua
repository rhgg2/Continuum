-- See docs/commandManager.md for the model.

--invariant: commands form a single flat namespace owned by mgr; scopes own keymaps + modal/passthrough only
--invariant: scope:register installs a gated wrapper into mgr.commands — invoke returns nil when the scope is not reachable on the stack
--invariant: scopes form a stack walked top-down; the bottom is the 'global' scope pushed at module load
--invariant: a modal scope without passthrough[name] blocks both key dispatch and invoke for names below it
--invariant: command return: nil = handled (stop dispatch); false = declined (let char queue see the keypress)
--invariant: a keymap entry is an array of keyspecs — multiple bindings dispatch to the same command
--invariant: layouts row 1 = base octave (15 semitones, C..D+1oct); row 2 = +1 octave (17 semitones, C..F+1oct)
--invariant: chars is folded from layouts at load time so the LUT can't drift from the declaration
--shape: keyspec = keyConstant | { keyConstant, mod1, mod2, ... }   -- mods OR'd into a single mask
--shape: keymapEntry = { keyspec, ... }                              -- array; each keyspec triggers the same command
--shape: noteChar = { semi = 0..16, octOff = 0..1 }
local util = require 'util'

local layouts = {
  qwerty = {
    { 'z','s','x','d','c','v','g','b','h','n','j','m',',','l','.' },
    { 'q','2','w','3','e','r','5','t','6','y','7','u','i','9','o','0','p' },
  },
  colemak = {
    { 'z','r','x','s','c','v','d','b','h','k','n','m',',','i','.' },
    { 'q','2','w','3','f','p','5','g','6','j','7','l','u','9','y','0',';' },
  },
  dvorak = {
    { ';','o','q','e','j','k','i','x','d','b','h','m','w','n','v' },
    { "'", '2',',','3','.','p','5','y','6','f','7','g','c','9','r','0','l' },
  },
  azerty = {
    { 'w','s','x','d','c','v','g','b','h','n','j',',',';','l',':' },
    { 'a',233,'z','"','e','r','(','t','-','y',232,'u','i',231,'o',224,'p' },
  },
}

local chars = {}
for name, layout in pairs(layouts) do
  local t = {}
  for octOff, row in ipairs(layout) do
    for semi, ch in ipairs(row) do
      local code = type(ch) == 'number' and ch or string.byte(ch)
      t[code] = { semi - 1, octOff - 1 }
    end
  end
  chars[name] = t
end

local cm = (...).cm

local mgr = {
  commands = {},          -- flat: name → fn (may be a wrap chain)
  gates    = {},          -- name → owning scope; absent = ungated (global)
  scopes   = {},
  stack    = {},
  layouts  = layouts,
}

----- Stack reachability
--
-- A name registered on scope S is reachable when S is on the stack and
-- no scope above S is modal-without-passthrough[name]. invoke gates on
-- this; key dispatch's keychain filter encodes the same predicate.

local function isReachable(scope, name)
  local idx
  for i, s in ipairs(mgr.stack) do
    if s == scope then idx = i; break end
  end
  if not idx then return false end
  for i = idx + 1, #mgr.stack do
    local s = mgr.stack[i]
    if s.modal and not (s.passthrough and s.passthrough[name]) then return false end
  end
  return true
end

----- Scope

--shape: scope = { keymap={}, modal=false?, passthrough={[name]=true}?, registered={[name]=true} }
local function newScope()
  local s = { keymap = {}, registered = {} }

  -- Module-side register installs a gated entry: invoke fires the fn
  -- only when the scope is reachable. Bookkeeping in `registered` lets
  -- callers iterate names this scope owns (vm uses this). Re-registration
  -- silently overwrites — the test harness exercises this when a spec
  -- builds a second vm against an already-populated cmgr.
  --contract: optional undoDesc wraps fn in util.atomic(undoDesc, fn) so REAPER's undo stack records this command as a labelled block
  function s:register(name, fn, undoDesc)
    self.registered[name] = true
    mgr.commands[name] = undoDesc and util.atomic(undoDesc, fn) or fn
    mgr.gates[name]    = self
  end

  --contract: registerAll value is either fn or {fn, undoDesc}; the tuple form opts the command into REAPER undo wrapping with the given label
  function s:registerAll(tbl)
    for name, v in pairs(tbl) do
      if type(v) == 'function' then self:register(name, v)
      else                          self:register(name, v[1], v[2]) end
    end
  end

  function s:bind(name, keys)        self.keymap[name] = keys end
  function s:bindAll(tbl)
    for name, keys in pairs(tbl) do self.keymap[name] = keys end
  end

  return s
end

----- Bottom of the stack
--
-- 'global' is an ordinary scope; it lives at the bottom and is never
-- popped. Commands registered via mgr:register are flat in mgr.commands
-- with no gate (always reachable). mgr.keymap aliases global.keymap so
-- root-level binds land on the bottom-of-stack keymap.

local global = newScope()
mgr.scopes.global = global
mgr.stack[1]      = global
mgr.keymap        = global.keymap

----- Manager-level surface
--
-- mgr:register installs an ungated command (always reachable). Pages and
-- modules use scope:register for mode-gated verbs; mgr:register is for
-- the unconditional ones (play, quit, switchPage).

--contract: delegates to the global scope — root-level commands are gated-to-global, which is always reachable; the duplicated registration body now lives only in scope:register
function mgr:register(name, fn, undoDesc) global:register(name, fn, undoDesc) end
function mgr:registerAll(tbl)             global:registerAll(tbl)             end

--contract: returns the bottom-of-stack ('global') keymap directly — used by dispatchers that want to fire ONLY root bindings (e.g. trackerPage's swing editor wants playPause/quit live but page-scoped commands off)
function mgr:rootKeymap() return global.keymap end

function mgr:bind(name, keys)    global:bind(name, keys) end
function mgr:bindAll(tbl)        global:bindAll(tbl)     end

--contract: wrap is a no-op if name has no registered command; wrappers stack (compose outward)
function mgr:wrap(name, wrapper)
  local orig = self.commands[name]
  if not orig then return end
  self.commands[name] = wrapper(orig)
end

--contract: doBefore/doAfter accept either a single name or an array of names
--contract: doAfter preserves the original command's return values (the dispatch signal)
--invariant: wraps compose inside the gate — when invoke skips a gated command, no doBefore / doAfter side-effect fires
function mgr:doBefore(name, before)
  if type(name) == 'table' then
    for _, n in ipairs(name) do self:doBefore(n, before) end
    return
  end
  self:wrap(name, function(orig)
    return function(...) before(); return orig(...) end
  end)
end

function mgr:doAfter(name, after)
  if type(name) == 'table' then
    for _, n in ipairs(name) do self:doAfter(n, after) end
    return
  end
  self:wrap(name, function(orig)
    return function(...)
      local r, s = orig(...); after(); return r, s
    end
  end)
end

----- Universal-argument prefix
--
-- Emacs-style numeric prefix. `beginPrefix` opens accumulation; the
-- dispatcher feeds digit and `/` characters via `appendPrefix`. The
-- next non-accumulating bound key calls `finishPrefix` to parse the
-- buffer and stash a pending value; the subsequent `invoke` reads it
-- as the first arg passed to the command, then clears all prefix state.
-- Commands needing the rational (num/den) call `prefixRational()` as a
-- non-consuming reader inside their body (state is live until invoke
-- returns). No negatives — direction is the bound command's job.

local prefixBuf, pendingPrefix = nil, nil
local pendingPrefixNum, pendingPrefixDen = nil, nil

local function clearPrefixState()
  prefixBuf = nil
  pendingPrefix, pendingPrefixNum, pendingPrefixDen = nil, nil, nil
end

--contract: buffer accepts only '0'..'9' and '/'; cancel/finish/invoke each leave the state inactive
function mgr:beginPrefix()    prefixBuf = ''           end
function mgr:isPrefixActive() return prefixBuf ~= nil end

function mgr:appendPrefix(ch)
  if not prefixBuf then return end
  if ch == '/' and prefixBuf:find('/', 1, true) then return end
  prefixBuf = prefixBuf .. ch
end

function mgr:cancelPrefix() clearPrefixState() end

--contract: empty buffer or unparseable input → nil pending value; '/' with empty numerator or denominator parses as nil; integer N stored as (N/1)
function mgr:finishPrefix()
  local buf = prefixBuf
  prefixBuf = nil
  pendingPrefix, pendingPrefixNum, pendingPrefixDen = nil, nil, nil
  if not buf or buf == '' then return nil end
  local num, den = buf:match('^(%d+)/(%d+)$')
  if num then
    local n, d = tonumber(num), tonumber(den)
    if d ~= 0 then
      pendingPrefix    = n / d
      pendingPrefixNum, pendingPrefixDen = n, d
    end
  elseif buf:match('^%d+$') then
    local n = tonumber(buf)
    pendingPrefix    = n
    pendingPrefixNum, pendingPrefixDen = n, 1
  end
  return pendingPrefix
end

--contract: non-consuming reader of the parsed rational; safe to call inside a command body. Returns (nil, nil) when no prefix is pending. State is cleared at the end of invoke, not by this call.
function mgr:prefixRational()
  return pendingPrefixNum, pendingPrefixDen
end

----- Scopes & stack

--contract: creates the scope on first request; idempotent thereafter
function mgr:scope(name)
  local s = self.scopes[name]
  if not s then
    s = newScope()
    self.scopes[name] = s
  end
  return s
end

local function asScope(s) return type(s) == 'string' and mgr.scopes[s] or s end

--contract: push(name|scope); creates a named scope if absent. Top-of-stack is the most recently pushed.
function mgr:push(s)
  s = type(s) == 'string' and self:scope(s) or s
  self.stack[#self.stack + 1] = s
  return s
end

--contract: pop(name|scope) asserts the named scope is currently on top; pops it
function mgr:pop(s)
  s = asScope(s)
  assert(self.stack[#self.stack] == s, 'cmgr:pop — scope is not on top of the stack')
  self.stack[#self.stack] = nil
end

----- Dispatch

--contract: returns nil when the command is unknown OR registered on a scope that is not currently reachable (off-stack or blocked by a modal above)
--contract: always prepends the pending prefix (defaulted to 1 when nothing is pending) as the first argument to the command body. Bodies that need to distinguish "user typed 1" from "no prefix" read prefixRational() — it returns (nil, nil) when nothing is pending. State stays live for the call so the body may read it; cleared on return ONLY if there was a pending prefix at entry, so a command body that opens prefix mode (beginPrefix) is not wiped out by its own invoke.
function mgr:invoke(name, ...)
  local fn = self.commands[name]
  if not fn then return end
  local scope = self.gates[name]
  if scope and not isReachable(scope, name) then return end
  local hadPending = pendingPrefix ~= nil
  local r1, r2 = fn(pendingPrefix or 1, ...)
  if hadPending then clearPrefixState() end
  return r1, r2
end

----- Keymap lookup
--
-- Keymap shadowing walks the same stack with the same modal+passthrough
-- rule, but on `scope.keymap` rather than the flat command table.

local function resolveKeys(name)
  for i = #mgr.stack, 1, -1 do
    local s = mgr.stack[i]
    local hit = s.keymap[name]
    if hit then return hit end
    if s.modal and not (s.passthrough and s.passthrough[name]) then return end
  end
end

function mgr:keysFor(name) return resolveKeys(name) end

--contract: returns one keymap per stack scope in top-down order; modal scopes filter lower keymaps to their passthrough name set, then halt the walk
function mgr:keychain()
  local out = {}
  for i = #self.stack, 1, -1 do
    out[#out + 1] = self.stack[i].keymap
    if self.stack[i].modal then
      local pass = self.stack[i].passthrough or {}
      for j = i - 1, 1, -1 do
        local view = {}
        for name, keys in pairs(self.stack[j].keymap) do
          if pass[name] then view[name] = keys end
        end
        out[#out + 1] = view
      end
      return out
    end
  end
  return out
end

-- ImGui injected so cmgr stays free of REAPER-side imports at module load.
function mgr:keySpec(spec, ImGui)
  if type(spec) ~= 'table' then return spec, ImGui.Mod_None end
  local mods = ImGui.Mod_None
  for i = 2, #spec do mods = mods | spec[i] end
  return spec[1], mods
end

----- Note layout

-- Re-read noteLayout on each call so a config change takes effect
-- without rebuilding vm.
function mgr:noteChars(char)
  return chars[cm:get('noteLayout')][char]
end

----- Key labels (human-readable bindings, for the help overlay)
--
-- ImGui injected (same reason as keySpec): cmgr stays free of REAPER
-- imports at load. The reverse LUT is built lazily on first call.

local keyNames
local function buildKeyNames(ImGui)
  local t = {}
  for i = 0, 25 do t[ImGui.Key_A + i] = string.char(65 + i) end
  for i = 0, 9  do t[ImGui.Key_0 + i] = tostring(i)      end
  for i = 1, 12 do t[ImGui['Key_F' .. i]] = 'F' .. i      end
  t[ImGui.Key_UpArrow],   t[ImGui.Key_DownArrow]  = '\xe2\x86\x91', '\xe2\x86\x93'
  t[ImGui.Key_LeftArrow], t[ImGui.Key_RightArrow] = '\xe2\x86\x90', '\xe2\x86\x92'
  t[ImGui.Key_Enter],     t[ImGui.Key_KeypadEnter] = 'Enter', 'Enter'
  t[ImGui.Key_Escape]    = 'Esc'
  t[ImGui.Key_Tab]       = 'Tab'
  t[ImGui.Key_Space]     = 'Space'
  t[ImGui.Key_Backspace] = 'Bksp'
  t[ImGui.Key_Delete]    = 'Del'
  t[ImGui.Key_Home],   t[ImGui.Key_End]      = 'Home', 'End'
  t[ImGui.Key_PageUp], t[ImGui.Key_PageDown] = 'PgUp', 'PgDn'
  t[ImGui.Key_Slash]        = '/'
  t[ImGui.Key_Minus]        = '-'
  t[ImGui.Key_Equal]        = '='
  t[ImGui.Key_Comma]        = ','
  t[ImGui.Key_Period]       = '.'
  t[ImGui.Key_LeftBracket]  = '['
  t[ImGui.Key_RightBracket] = ']'
  t[ImGui.Key_GraveAccent]  = '`'
  t[ImGui.Key_Apostrophe]   = "'"
  t[ImGui.Key_Semicolon]    = ';'
  t[ImGui.Key_Backslash]    = '\\'
  return t
end

-- On macOS, ReaImGui's MacOSXBehaviors maps the \xe2\x8c\x98 key to Mod_Ctrl and
-- the physical \xe2\x8c\x83 to Mod_Super, so the labels invert vs. Windows/Linux.
local modLabels
local function buildModLabels()   -- parallel to the `order` list in keyLabel
  local os = reaper.GetOS()
  if os:find('OSX') or os:find('mac') then return { 'Cmd', 'Alt', 'Shift', 'Ctrl' } end
  return { 'Ctrl', 'Alt', 'Shift', os:find('Win') and 'Win' or 'Super' }
end

function mgr:keyLabel(spec, ImGui)
  keyNames  = keyNames  or buildKeyNames(ImGui)
  modLabels = modLabels or buildModLabels()
  local key, mods = self:keySpec(spec, ImGui)
  local order = { ImGui.Mod_Ctrl, ImGui.Mod_Alt, ImGui.Mod_Shift, ImGui.Mod_Super }
  local parts = {}
  for i, m in ipairs(order) do
    if (mods & m) ~= 0 then parts[#parts + 1] = modLabels[i] end
  end
  parts[#parts + 1] = keyNames[key] or '?'
  return table.concat(parts, '+')
end

--contract: all bound keyspecs for the reachable command joined by ' / ', or nil if unbound on the current stack
function mgr:keyLabels(name, ImGui)
  local specs = self:keysFor(name)
  if not specs then return nil end
  local out = {}
  for _, spec in ipairs(specs) do out[#out + 1] = self:keyLabel(spec, ImGui) end
  return table.concat(out, ' / ')
end

return mgr
