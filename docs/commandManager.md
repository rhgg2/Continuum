# commandManager

Central registry for named actions and the keys that invoke them.
Managers register command handlers by name — each owns the commands
that close over its state. rm binds default keys and drives dispatch
from its ImGui render loop. Also holds the physical-keyboard →
note-input layouts used when typing notes into the grid.

Two orthogonal tables live on the manager:

- `commands[name] = fn` — what the command does. **Flat namespace.**
  One fn per name, owned by exactly one module. There is no scoped
  copy of `commands`; the scope a verb belongs to is recorded
  separately in `gates[name]` and only affects whether `invoke` will
  fire it.
- `keymap[name]   = { keyspec, ... }` — which keys trigger it. **Per
  scope.** Each scope carries its own keymap; bindings are what stack
  and shadow.

Commands are flat because a verb has one meaning. *deleteSel* always
means "delete the selection" — that doesn't depend on which scope is
on top. What changes per mode is which **key** fires which verb, not
what the verb itself does. So bindings are scoped; commands aren't.

Keeping the tables name-addressable (rather than closing keys over
handlers directly) lets rm invoke commands by name outside the keymap
path — mouse-wheel scrolling and the swing editor both do this — and
lets vm wrap existing commands without threading through the dispatch
loop.

## Registration lifecycle

```
newCommandManager(cm)                  -- empty commands + empty keymap
  → newTrackerView(tm, cm, cmgr)        -- vm registers editing commands;
                                       --   ec / clipboard self-register
                                       --   navigation + clipboard commands;
                                       --   then vm applies wrap(...)
  → newTrackerPage(vm, cm, cmgr)       -- rm registers UX commands and
                                       --   calls installDefaultKeymap(ImGui)
```

Registration is split by ownership rather than packed into one site:

- **ec** (`ec:registerCommands(cmgr)`, called from vm) — navigation and
  selection-shape commands.
- **clipboard** (`clipboard:registerCommands(cmgr)`, called from vm) —
  `copy`, `paste`.
- **vm** (`cmgr:registerAll`) — editing commands, transport, column
  management, display, swing/temperament cycling, and cross-layer composites
  like `cut` (which combines `clipboard:copy` with `vm`'s
  `deleteSelection`).
- **rm** (`cmgr:registerAll`) — commands whose effect lives in rm-only
  state: modals (`setRPB`, `addTypedCol`), confirm-scoped variants of
  vm's domain verbs (`reswing`, `quantize`, `quantizeKeepRealised`),
  the swing editor (`openSwingEditor`), and `quit`.

After registration vm applies `wrap` calls for cross-cutting behaviour
(see below). rm installs the default keymap at construction; users
will eventually layer overrides on top.

## Scope stack

Scopes form a stack. The `'global'` scope sits at the bottom (pushed
at module load, never popped); `mgr.keymap` aliases its keymap so
unscoped binds land there. Above it: the active page scope (`tracker`
or `sample`), pushed by `coord:setActive` and popped on page switch.
Above that: optional overlay scopes (`region` today; letter-chord
menus later).

A scope's `register(name, fn)` writes `mgr.commands[name] = fn` and
records `mgr.gates[name] = scope`. At `invoke` time the gate is
checked: the fn fires only if the scope is somewhere on the stack
AND no modal scope above it blocks the name. So a module's `register`
is its own guard — the command can't accidentally fire when its mode
is inactive, even if reached by programmatic invoke or a stray
binding. `mgr:register` (ungated) is reserved for verbs whose mode
is always-on: `play`, `quit`, `switchPage`.

Bindings shadow by ordinary top-down keymap walk. A scope can
declare `modal=true` with a `passthrough = { [name]=true, ... }`
set; on hitting that scope, the walk continues only for names in
`passthrough`, otherwise it stops there. `keysFor` and `keychain`
both honour this. The gate on `invoke` honours the same rule, so
the two paths agree: a key that doesn't dispatch in a given mode
will also not invoke its command.

The same key may bind different verbs in different scopes — region's
Delete fires `regionDrop`; tracker's Delete fires `deleteSel`. Two
distinct verbs, one shared key. No name collision; no wrapper hack.

`mgr:push(scopeOrName)` / `mgr:pop(scopeOrName)` are the only
mutators. `pop` asserts the popped scope is on top, so an
out-of-order pop is loud rather than silent.

## Dispatch & result protocol

The dispatcher iterates `cmgr:keychain()` — one filtered keymap per
stack scope, top-down, modal-aware. It matches ImGui key + modifier
state and invokes `cmgr.commands[name]()` via the same walker. The
return value is a single boolean-ish:

| return          | meaning                                                    |
|-----------------|------------------------------------------------------------|
| `nil` (default) | command handled; stop scanning further bindings this frame |
| `false`         | command declined the keypress; let the char queue see it   |

UI effects (open a modal, open the swing editor, quit) are not
expressed in the return value — the commands that produce them are
registered by the layer that owns the effect. rm owns the modal,
swing-editor, and quit commands and closes over its own state; vm
exposes the underlying domain verbs (e.g. `vm:reswingSelection`,
`vm:reswingAll`) for rm's confirm-scoped wrappers to call.

Commands invoked by name outside the keymap path (mouse wheel,
swing-editor buttons) ignore the return value and just run for effect.

## Wrapping

`wrap(name, wrapper)` replaces `commands[name]` with
`wrapper(originalFn)`. It exists so vm can bolt cross-cutting behaviour
onto whole groups of commands without touching each handler:

- **mark-mode paste cancel** — first paste press in mark mode clears the
  selection instead of pasting, so the explicit second press pastes at
  the cursor.
- **auto-unstick** — nudge / grow / duplicate / interpolate / row-insert
  / reswing / quantize commands drop the sticky-selection flags after
  running, so the edited region stays visible but doesn't extend on the
  next cursor move.
- **auto-clear selection** — after `delete` / `deleteSel` / `cut` the
  affected events are gone, so the empty selection rect is cleared.

Wrappers compose; calling `wrap` on an already-wrapped command stacks
outside the previous wrapper.

## Note-input layouts

`layouts` declares four physical-keyboard maps (`qwerty`, `colemak`,
`dvorak`, `azerty`). Each layout is a two-row array:

- **row 1** (Z-row on qwerty) = base octave, 15 semitones, C → D+1oct
- **row 2** (Q-row on qwerty) = +1 octave, 17 semitones, C → F+1oct

Entries are single-char strings or integer codepoints (for non-ASCII
keys on azerty). Positions across layouts are musically corresponding —
the Nth slot in row 1 is the same semitone in every layout.

At load time, `layouts` is folded into `chars[name][code] = { semi,
octOff }` — a flat per-layout lookup keyed by character code. The
derivation lives next to the declaration so the two stay in sync; edit
`layouts` and the LUT rebuilds on next load.

`cmgr:noteChars(char)` resolves a typed character under the active
layout (`cm:get('noteLayout')`). The layout is re-read on every call so
a config change takes effect without rebuilding vm.

## Conventions

- **Command names are flat strings.** `advBy0` … `advBy9` are generated
  in a loop rather than using a namespaced form — the dispatch table is
  a simple string-keyed map, not a tree.
- **Keyspec shape.** Each entry in `keymap[name]` is either a plain key
  constant or `{ key, mod1, mod2, ... }`. Mods are OR'd together.
- **Multiple bindings per command** are supported — the `keys` array
  holds any number of keyspecs, all dispatch to the same command.
- **No automatic unregister.** Commands live for the session; replacing
  one is done via `register` (overwrite) or `wrap` (compose).
