-- See docs/commandManager.md for the model.

--invariant: cmgr owns a flat command namespace; scopes own keymaps + modal/passthrough only
--invariant: scope:register installs a gated wrapper; invoke returns nil when scope is unreachable
--invariant: scopes form a stack walked top-down; the bottom is the 'global' scope pushed at module load
--invariant: a modal scope without passthrough[name] blocks both key dispatch and invoke for names below it
--invariant: command return: nil = handled (stop dispatch); false = declined (let char queue see the keypress)
--invariant: spring-loaded scope: redirect[] reinterprets; keepAlive[] passes; else onBail()
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

local cmgr = {
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
  for i, s in ipairs(cmgr.stack) do
    if s == scope then idx = i; break end
  end
  if not idx then return false end
  for i = idx + 1, #cmgr.stack do
    local s = cmgr.stack[i]
    if s.modal and not (s.passthrough and s.passthrough[name]) then return false end
  end
  return true
end

----- Scope

--shape: scope = { keymap={}, registered={}, modal?, passthrough?, springLoaded?, redirect={[name]=fn}?, keepAlive={[name]=true}?, onBail? }
local function newScope(name)
  local s = { keymap = {}, registered = {}, name = name }

  -- Module-side register installs a gated entry: invoke fires the fn
  -- only when the scope is reachable. Bookkeeping in `registered` lets
  -- callers iterate names this scope owns (vm uses this). Re-registration
  -- silently overwrites — the test harness exercises this when a spec
  -- builds a second vm against an already-populated cmgr.
  --contract: optional undoDesc wraps fn in util.atomic(undoDesc, fn) so REAPER's undo stack records this command as a labelled block
  function s:register(name, fn, undoDesc)
    self.registered[name] = true
    cmgr.commands[name] = undoDesc and util.atomic(undoDesc, fn) or fn
    cmgr.gates[name]    = self
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
-- 'global' is fixed here; cmgr.keymap aliases global.keymap; cmgr:register writes to it ungated.

local global = newScope('global')
cmgr.scopes.global = global
cmgr.stack[1]      = global
cmgr.keymap        = global.keymap

----- Manager-level surface
-- cmgr:register is for unconditional verbs (play, quit, switchPage); scope:register for mode-gated ones.

--contract: delegates to the global scope — root-level commands are gated-to-global, which is always reachable; the duplicated registration body now lives only in scope:register
function cmgr:register(name, fn, undoDesc) global:register(name, fn, undoDesc) end
function cmgr:registerAll(tbl)             global:registerAll(tbl)             end

--contract: returns the bottom-of-stack ('global') keymap directly — used by dispatchers that want to fire ONLY root bindings (e.g. trackerPage's swing editor wants playPause/quit live but page-scoped commands off)
function cmgr:rootKeymap() return global.keymap end

function cmgr:bind(name, keys)    global:bind(name, keys) end
function cmgr:bindAll(tbl)        global:bindAll(tbl)     end

--contract: wrap is a no-op if name has no registered command; wrappers stack (compose outward)
function cmgr:wrap(name, wrapper)
  local orig = self.commands[name]
  if not orig then return end
  self.commands[name] = wrapper(orig)
end

--contract: doBefore/doAfter accept either a single name or an array of names
--contract: doAfter preserves the original command's return values (the dispatch signal)
--invariant: wraps compose inside the gate — when invoke skips a gated command, no doBefore / doAfter side-effect fires
function cmgr:doBefore(name, before)
  if type(name) == 'table' then
    for _, n in ipairs(name) do self:doBefore(n, before) end
    return
  end
  self:wrap(name, function(orig)
    return function(...) before(); return orig(...) end
  end)
end

function cmgr:doAfter(name, after)
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
function cmgr:beginPrefix()    prefixBuf = ''           end
function cmgr:isPrefixActive() return prefixBuf ~= nil end

function cmgr:appendPrefix(ch)
  if not prefixBuf then return end
  if ch == '/' and prefixBuf:find('/', 1, true) then return end
  prefixBuf = prefixBuf .. ch
end

function cmgr:cancelPrefix() clearPrefixState() end

--contract: empty buffer or unparseable input → nil pending value; '/' with empty numerator or denominator parses as nil; integer N stored as (N/1)
function cmgr:finishPrefix()
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
function cmgr:prefixRational()
  return pendingPrefixNum, pendingPrefixDen
end

----- Scopes & stack

--contract: creates the scope on first request; idempotent thereafter
function cmgr:scope(name)
  local s = self.scopes[name]
  if not s then
    s = newScope(name)
    self.scopes[name] = s
  end
  return s
end

local function asScope(s) return type(s) == 'string' and cmgr.scopes[s] or s end

--contract: push(name|scope); creates a named scope if absent. Top-of-stack is the most recently pushed.
function cmgr:push(s)
  s = type(s) == 'string' and self:scope(s) or s
  self.stack[#self.stack + 1] = s
  return s
end

--contract: pop(name|scope) asserts the named scope is currently on top; pops it
function cmgr:pop(s)
  s = asScope(s)
  assert(self.stack[#self.stack] == s, 'cmgr:pop — scope is not on top of the stack')
  self.stack[#self.stack] = nil
end

----- Dispatch

--contract: returns nil when the command is unknown OR registered on a scope that is not currently reachable (off-stack or blocked by a modal above)
--contract: always prepends the pending prefix (defaulted to 1 when nothing is pending) as the first argument to the command body. Bodies that need to distinguish "user typed 1" from "no prefix" read prefixRational() — it returns (nil, nil) when nothing is pending. State stays live for the call so the body may read it; cleared on return ONLY if there was a pending prefix at entry, so a command body that opens prefix mode (beginPrefix) is not wiped out by its own invoke.
--contract: spring-loaded scope: redirect[] runs fn in-place; keepAlive[] passes; else onBail()
function cmgr:invoke(name, ...)
  local fn  = self.commands[name]
  local top = self.stack[#self.stack]
  local spring     = (top and top.springLoaded) and top or nil
  local redirected = spring and spring.redirect and spring.redirect[name]
  if not fn and not redirected then return end
  if spring then
    if redirected then
      fn = redirected                                  -- reinterpret onto the overlay; stay armed
    elseif self.gates[name] ~= spring and not (spring.keepAlive and spring.keepAlive[name]) then
      spring.onBail()                                  -- any other command: disarm, then dispatch through
    end
  end
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
  for i = #cmgr.stack, 1, -1 do
    local s = cmgr.stack[i]
    local hit = s.keymap[name]
    if hit then return hit end
    if s.modal and not (s.passthrough and s.passthrough[name]) then return end
  end
end

function cmgr:keysFor(name) return resolveKeys(name) end

--contract: returns one keymap per stack scope in top-down order; modal scopes filter lower keymaps to their passthrough name set, then halt the walk
function cmgr:keychain()
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
function cmgr:keySpec(spec, ImGui)
  if type(spec) ~= 'table' then return spec, ImGui.Mod_None end
  local mods = ImGui.Mod_None
  for i = 2, #spec do mods = mods | spec[i] end
  return spec[1], mods
end

----- Binding-edit queries (scope-aware)
-- see docs/commandManager.md § Binding-edit queries

--contract: reachable command for spec's key (keychain top-down); skips exceptName; nil if free
function cmgr:commandAtKey(spec, exceptName, ImGui)
  local key, mods = self:keySpec(spec, ImGui)
  for _, keymap in ipairs(self:keychain()) do
    for name, entry in pairs(keymap) do
      if name ~= exceptName then
        for _, bound in ipairs(entry) do
          local boundKey, boundMods = self:keySpec(bound, ImGui)
          if boundKey == key and boundMods == mods then return name end
        end
      end
    end
  end
end

--contract: scope to edit name's binding in: scope currently binding it, else its gate scope
function cmgr:bindingSite(name)
  for i = #self.stack, 1, -1 do
    local scope = self.stack[i]
    if scope.keymap[name] then return scope.name end
    if scope.modal and not (scope.passthrough and scope.passthrough[name]) then break end
  end
  return (self.gates[name] or global).name
end

----- Note layout

-- Re-read noteLayout on each call so a config change takes effect
-- without rebuilding vm.
function cmgr:noteChars(char)
  return chars[cm:get('noteLayout')][char]
end

----- Key labels (human-readable bindings, for the help overlay)
--
-- ImGui injected (same reason as keySpec): cmgr stays free of REAPER
-- imports at load. The reverse LUT is built lazily on first call.

-- macOS shows the non-printables its UI font covers as keycap glyphs (⏎ ⎋ ⌫ ⌦ …);
-- Tab/PgUp/PgDn lack glyphs there, so they keep words like Windows/Linux. See buildModOrder.
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
  local os = reaper.GetOS()
  if os:find('OSX') or os:find('mac') then
    t[ImGui.Key_Enter], t[ImGui.Key_KeypadEnter] = '\xe2\x8f\x8e', '\xe2\x8f\x8e'  -- ⏎
    t[ImGui.Key_Escape]    = '\xe2\x8e\x8b'  -- ⎋
    t[ImGui.Key_Backspace] = '\xe2\x8c\xab'  -- ⌫
    t[ImGui.Key_Delete]    = '\xe2\x8c\xa6'  -- ⌦
    t[ImGui.Key_Home], t[ImGui.Key_End] = '\xe2\x86\x96', '\xe2\x86\x98'  -- ↖ ↘
  end
  return t
end

-- Shift-only bindings show the produced glyph (! @ { } | : etc.) rather than "Shift+base".
-- - and = are omitted so they keep their "Shift+-" / "Shift+=" form.
local shiftGlyph
local function buildShiftGlyphs(ImGui)
  local t = {}
  local digits = { [0] = ')', '!', '@', '#', '$', '%', '^', '&', '*', '(' }
  for i = 0, 9 do t[ImGui.Key_0 + i] = digits[i] end
  t[ImGui.Key_LeftBracket]  = '{'
  t[ImGui.Key_RightBracket] = '}'
  t[ImGui.Key_Backslash]    = '|'
  t[ImGui.Key_Semicolon]    = ':'
  t[ImGui.Key_Apostrophe]   = '"'
  t[ImGui.Key_Comma]        = '<'
  t[ImGui.Key_Period]       = '>'
  t[ImGui.Key_Slash]        = '?'
  t[ImGui.Key_GraveAccent]  = '~'
  return t
end

-- macOS inverts Mod_Ctrl/Mod_Super (ReaImGui MacOSXBehaviors): Mod_Ctrl is ⌘,
-- Mod_Super is ⌃. Mac shows glyphs in canonical ⌃⌥⇧⌘ order, joined tight (⇧⌘K).
local modOrder, modSep
local function buildModOrder(ImGui)
  local os = reaper.GetOS()
  if os:find('OSX') or os:find('mac') then
    return {
      { ImGui.Mod_Super, '\xe2\x8c\x83' },  -- ⌃ Control
      { ImGui.Mod_Alt,   '\xe2\x8c\xa5' },  -- ⌥ Option
      { ImGui.Mod_Shift, '\xe2\x87\xa7' },  -- ⇧ Shift
      { ImGui.Mod_Ctrl,  '\xe2\x8c\x98' },  -- ⌘ Command
    }, ''
  end
  return {
    { ImGui.Mod_Ctrl,  'Ctrl' },
    { ImGui.Mod_Alt,   'Alt' },
    { ImGui.Mod_Shift, 'Shift' },
    { ImGui.Mod_Super, os:find('Win') and 'Win' or 'Super' },
  }, '+'
end

function cmgr:keyLabel(spec, ImGui)
  keyNames   = keyNames   or buildKeyNames(ImGui)
  shiftGlyph = shiftGlyph or buildShiftGlyphs(ImGui)
  if not modOrder then modOrder, modSep = buildModOrder(ImGui) end
  local key, mods = self:keySpec(spec, ImGui)
  if mods == ImGui.Mod_Shift and shiftGlyph[key] then return shiftGlyph[key] end
  local parts = {}
  for _, m in ipairs(modOrder) do
    if (mods & m[1]) ~= 0 then parts[#parts + 1] = m[2] end
  end
  parts[#parts + 1] = keyNames[key] or '?'
  return table.concat(parts, modSep)
end

--contract: list of human labels, one per bound keyspec of the reachable command, or nil if unbound
function cmgr:keyLabelList(name, ImGui)
  local specs = self:keysFor(name)
  if not specs then return nil end
  local out = {}
  for _, spec in ipairs(specs) do out[#out + 1] = self:keyLabel(spec, ImGui) end
  return out
end

--contract: keyLabelList joined by ' / ', or nil if unbound on the current stack
function cmgr:keyLabels(name, ImGui)
  local list = self:keyLabelList(name, ImGui)
  return list and table.concat(list, ' / ')
end

----- Binding tokens (stable ASCII; the on-disk / hand-edit form)
-- OS-independent ASCII ("Ctrl+Z"); mods in Ctrl+Shift+Alt+Super order, no macOS glyph inversion.

local keyTokens, modTokenList, tokenKeys, modByName

local function buildKeyTokens(ImGui)
  local t = {}
  for i = 0, 25 do t[ImGui.Key_A + i]       = string.char(65 + i) end
  for i = 0, 9  do t[ImGui.Key_0 + i]       = tostring(i)         end
  for i = 0, 9  do t[ImGui.Key_Keypad0 + i] = 'Keypad' .. i       end
  for i = 1, 12 do t[ImGui['Key_F' .. i]]   = 'F' .. i            end
  t[ImGui.Key_Space]        = 'Space'
  t[ImGui.Key_Enter]        = 'Enter'
  t[ImGui.Key_KeypadEnter]  = 'KeypadEnter'
  t[ImGui.Key_Escape]       = 'Escape'
  t[ImGui.Key_Tab]          = 'Tab'
  t[ImGui.Key_Backspace]    = 'Backspace'
  t[ImGui.Key_Delete]       = 'Delete'
  t[ImGui.Key_Insert]       = 'Insert'
  t[ImGui.Key_Home]         = 'Home'
  t[ImGui.Key_End]          = 'End'
  t[ImGui.Key_PageUp]       = 'PageUp'
  t[ImGui.Key_PageDown]     = 'PageDown'
  t[ImGui.Key_UpArrow]      = 'Up'
  t[ImGui.Key_DownArrow]    = 'Down'
  t[ImGui.Key_LeftArrow]    = 'Left'
  t[ImGui.Key_RightArrow]   = 'Right'
  t[ImGui.Key_Comma]        = 'Comma'
  t[ImGui.Key_Period]       = 'Period'
  t[ImGui.Key_Slash]        = 'Slash'
  t[ImGui.Key_Semicolon]    = 'Semicolon'
  t[ImGui.Key_Apostrophe]   = 'Apostrophe'
  t[ImGui.Key_Minus]        = 'Minus'
  t[ImGui.Key_Equal]        = 'Equal'
  t[ImGui.Key_LeftBracket]  = 'LeftBracket'
  t[ImGui.Key_RightBracket] = 'RightBracket'
  t[ImGui.Key_GraveAccent]  = 'Grave'
  t[ImGui.Key_Backslash]    = 'Backslash'
  t[ImGui.Key_KeypadSubtract] = 'KeypadSubtract'
  return t
end

local function buildModTokens(ImGui)
  return {
    { ImGui.Mod_Ctrl,  'Ctrl'  },
    { ImGui.Mod_Shift, 'Shift' },
    { ImGui.Mod_Alt,   'Alt'   },
    { ImGui.Mod_Super, 'Super' },
  }
end

local function ensureTokenTables(ImGui)
  if keyTokens then return end
  keyTokens, modTokenList = buildKeyTokens(ImGui), buildModTokens(ImGui)
  tokenKeys, modByName = {}, {}
  for code, name in pairs(keyTokens)  do tokenKeys[name] = code end
  for _, entry in ipairs(modTokenList) do modByName[entry[2]] = entry[1] end
end

--contract: spec -> stable ASCII token ("Ctrl+Z"); nil if the key has no token name
function cmgr:tokenForSpec(spec, ImGui)
  ensureTokenTables(ImGui)
  local key, mods = self:keySpec(spec, ImGui)
  local name = keyTokens[key]
  if not name then return nil end
  local parts = {}
  for _, entry in ipairs(modTokenList) do
    if (mods & entry[1]) ~= 0 then parts[#parts + 1] = entry[2] end
  end
  parts[#parts + 1] = name
  return table.concat(parts, '+')
end

--contract: token -> keyspec (bare key | {key, mod...}); (nil, err) on an unknown key/modifier
function cmgr:specForToken(token, ImGui)
  ensureTokenTables(ImGui)
  local parts = {}
  for part in token:gmatch('[^+]+') do parts[#parts + 1] = part end
  if #parts == 0 then return nil, 'empty token' end
  local key = tokenKeys[parts[#parts]]
  if not key then return nil, 'unknown key "' .. parts[#parts] .. '"' end
  if #parts == 1 then return key end
  local spec = { key }
  for i = 1, #parts - 1 do
    local mod = modByName[parts[i]]
    if not mod then return nil, 'unknown modifier "' .. parts[i] .. '"' end
    spec[#spec + 1] = mod
  end
  return spec
end

----- Binding overrides (persisted, hand-editable)
-- keyBindings[scopeName][cmd]={token,...} overlays code defaults; rebind writes live+persisted.

--contract: a malformed token is warned and skipped; the command keeps its other (good) bindings
function cmgr:loadOverrides(ImGui)
  for scopeName, cmds in pairs(cm:get('keyBindings')) do
    local scope = self.scopes[scopeName]
    if scope then
      for name, tokens in pairs(cmds) do
        local specs = {}
        for _, token in ipairs(tokens) do
          local spec, err = self:specForToken(token, ImGui)
          if spec then specs[#specs + 1] = spec
          else util.print('keyBindings ' .. scopeName .. '.' .. name .. ': ' .. err .. ' - skipped') end
        end
        scope.keymap[name] = specs
      end
    end
  end
end

--contract: overwrites the scope's binding for name and persists it as tokens (global tier)
function cmgr:rebind(scopeName, name, specs, ImGui)
  local scope = self.scopes[scopeName]
  if not scope then return end
  scope.keymap[name] = specs
  local overrides = cm:get('keyBindings')
  overrides[scopeName] = overrides[scopeName] or {}
  local tokens = {}
  for _, spec in ipairs(specs) do tokens[#tokens + 1] = self:tokenForSpec(spec, ImGui) end
  overrides[scopeName][name] = tokens
  cm:set('global', 'keyBindings', overrides)
end

return cmgr
