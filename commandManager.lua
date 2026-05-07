-- See docs/commandManager.md for the model.

--@map:invariant commands and keymap are orthogonal name-keyed tables; a name may live in either alone
--@map:invariant root scope is global; named scopes are pages; at most one scope is active at a time
--@map:invariant active-scope entries shadow root entries during invoke and keychain lookups (first hit wins)
--@map:invariant command return: nil = handled (stop dispatch); false = declined (let char queue see the keypress)
--@map:invariant a keymap entry is an array of keyspecs — multiple bindings dispatch to the same command
--@map:invariant layouts row 1 = base octave (15 semitones, C..D+1oct); row 2 = +1 octave (17 semitones, C..F+1oct)
--@map:invariant chars is folded from layouts at load time so the LUT can't drift from the declaration

--@map:shape keyspec = keyConstant | { keyConstant, mod1, mod2, ... }   -- mods OR'd into a single mask
--@map:shape keymapEntry = { keyspec, ... }                              -- array; each keyspec triggers the same command
--@map:shape noteChar = { semi = 0..16, octOff = 0..1 }

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

----- Scope

--@map:contract wrap is a no-op if name has no registered command; wrappers stack (compose outward)
--@map:contract doBefore/doAfter accept either a single name or an array of names
--@map:contract doAfter preserves the original command's return values (it's the dispatch signal)
local function attachScope(scope)
  function scope:register(name, fn) self.commands[name] = fn end

  function scope:registerAll(tbl)
    for name, fn in pairs(tbl) do self.commands[name] = fn end
  end

  function scope:bind(name, keys) self.keymap[name] = keys end

  function scope:bindAll(tbl)
    for name, keys in pairs(tbl) do self.keymap[name] = keys end
  end

  function scope:wrap(name, wrapper)
    local orig = self.commands[name]
    if not orig then return end
    self.commands[name] = wrapper(orig)
  end

  function scope:doBefore(name, before)
    if type(name) == 'table' then
      for _, n in ipairs(name) do self:doBefore(n, before) end
      return
    end
    self:wrap(name, function(orig)
      return function () before(); return orig() end
    end)
  end

  function scope:doAfter(name, after)
    if type(name) == 'table' then
      for _, n in ipairs(name) do self:doAfter(n, after) end
      return
    end
    self:wrap(name, function(orig)
      return function ()
        local r, s = orig(); after(); return r, s
      end
    end)
  end

  return scope
end

local function newScope()
  return attachScope({ commands = {}, keymap = {} })
end

--@map:contract mgr.commands / mgr.keymap alias the root scope's tables; rm reads them directly in dispatch
--@map:contract mgr-level register/bind/wrap/doBefore/doAfter operate on the root scope only
function newCommandManager(cm)
  local root   = newScope()
  local scopes = {}

  local mgr = {
    commands    = root.commands,    -- alias: tests and dispatch read here
    keymap      = root.keymap,
    layouts     = layouts,
    root        = root,
    scopes      = scopes,
    activeScope = nil,
  }

  function mgr:register(name, fn)     root:register(name, fn) end
  function mgr:registerAll(tbl)       root:registerAll(tbl) end
  function mgr:bind(name, keys)       root:bind(name, keys) end
  function mgr:bindAll(tbl)           root:bindAll(tbl) end
  function mgr:wrap(name, wrapper)    root:wrap(name, wrapper) end
  function mgr:doBefore(name, before) root:doBefore(name, before) end
  function mgr:doAfter(name, after)   root:doAfter(name, after) end

  ----- Scopes

  --@map:contract creates the scope on first request; idempotent thereafter
  function mgr:scope(name)
    local s = scopes[name]
    if not s then
      s = newScope()
      scopes[name] = s
    end
    return s
  end

  --@map:contract pass nil to clear active scope (drop back to root-only resolution)
  function mgr:setActive(name) self.activeScope = name end

  function mgr:dropScope(name) scopes[name] = nil end

  ----- Lookup

  --@map:contract no-op (returns nil) if no scope resolves the name; never raises on unknown
  function mgr:invoke(name, ...)
    local s  = self.activeScope and scopes[self.activeScope]
    local fn = (s and s.commands[name]) or root.commands[name]
    if fn then return fn(...) end
  end

  function mgr:keychain()
    local s = self.activeScope and scopes[self.activeScope]
    if s then return { s.keymap, root.keymap } end
    return { root.keymap }
  end

  function mgr:keysFor(name)
    for _, km in ipairs(self:keychain()) do
      if km[name] then return km[name] end
    end
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

  return mgr
end
