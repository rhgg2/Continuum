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

## Binding tokens

1. A **token** is a chord written as stable ASCII — `Ctrl+Shift+Z`,
   `Super+P`, `Up`, `Space`. The modifiers come first in
   `Ctrl+Shift+Alt+Super` order, and the key last.

1. A token names an ImGui modifier rather than a platform's glyph, so it
   carries no macOS inversion: `Ctrl+Z` is ⌘Z on a Mac and Ctrl+Z
   elsewhere, exactly as the keyspec it parses to. `keyLabel` renders the
   platform's glyphs; the token stays ASCII.

1. `specForToken` parses one and `tokenForSpec` prints one. The manifest
   declares its keys as tokens and a persisted override stores them, so a
   declaration and an override spell a chord the same way.

## Manifest

1. A scope's **manifest** declares every command that scope registers.
   Each **entry** names one command and carries a **label** for display,
   and its **keys** as binding tokens where the command has any.
   `manifest.lua` holds one such table per scope, each entry built by its
   local `command` helper.

1. A scope's entries are declared under a **group**, the name the
   cheat-sheet gives the box they read in. The group is the entry's own
   fact, so no consumer holds a list of command names; where the box
   draws is the consumer's (`docs/help.md` § What's where).

1. A group's entries are a list, so the order a command is declared in is
   a fact the declaration carries, and a consumer reading the group reads
   that order. The groups within a scope are unordered, since a consumer
   orders the groups it shows itself.

1. A **consumer** is a surface reading the manifest for its own slice, and
   it never reads another consumer's output: `bindAll` takes each entry's
   name and keys, the cheat-sheet its label and group (`docs/help.md`
   § What's where). An entry carries no rendering, so how a chord prints
   and where a box draws stay with the consumer.

1. `installManifest(manifest, ImGui)` parses each entry's tokens into
   keyspecs, writes them into its scope's keymap, stamps each entry with
   the group it was declared under, and hangs the groups off the scope as
   `scope.manifest`. A token that does not parse raises, naming the
   command. It runs from continuum's wiring before `loadOverrides`, so a
   persisted rebinding still wins over the declared default.

1. A command resolves to exactly one entry. Two scopes declaring the same
   name raises at install, since the flat namespace gives that name one
   body and one gate.

1. `entry(name)` returns a command's entry, whichever scope declares it,
   and raises on a name no manifest declares. A consumer reads its
   labels through it — the F1 cheat-sheet names a rebinding's victim
   whether or not the victim's page is showing.

1. `auditManifests()` checks each declared scope both ways: an entry the
   scope does not register raises, as does a registration its manifest
   omits. It runs at the end of wiring, once every command has its body.

1. Every scope that registers a command declares a manifest, and a
   registration under a scope with none raises. A scope that registers
   nothing declares nothing: `arrangeSelect` and `arrangeReplace` only
   redirect keys, so the audit passes over them.

1. A command family minted in a loop declares its entries in that loop,
   labels included: the tracker's `advBy0`–`advBy9` are ten entries in
   the group `Advance`, so no command is registered outside a manifest.

1. A **family** is the table those entries share. It carries the label
   the family reads under and its **members** in declaration order. Each
   member also carries its **base**, the unmasked token its declared
   chord is the masked form of: `advBy3` declares `Ctrl+3` over the base
   `3`, while the drop family's mask is empty and `drop36` declares its
   base `Shift+A` as it stands.

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

## Surface

1. The **surface** is what the stack can reach: `mgr:surface()` returns
   the entries of every scope on the stack, minus the names a modal scope
   above blocks. It answers the question `invoke` gates on, so a command
   on the surface is one that would fire.

1. The entries come bottom of stack first, each group's in declaration
   order, so a group split across scopes reads global first and the page's
   own commands after.

1. The cheat-sheet is its consumer today: it buckets the surface by group,
   and a group with no reachable entry draws nothing.

## Spring-loaded scope

A scope may set `springLoaded = true` to act as a transient overlay
that auto-dismisses. It is non-modal, so the keychain still reaches
the scopes below; what it adds is `invoke`-time interception while it
is on top of the stack:

- `redirect = { [name] = fn }` — invoking `name` runs `fn` instead of
  the command and the overlay *stays*. This reinterprets a familiar
  verb onto the overlay's subject (region mode redirects `paste`,
  `nudgeForward`, `growNote`, … onto the armed group instance).
- `keepAlive = { [name] = true }` — invoking `name` runs normally and
  the overlay *stays*. Navigation lives here.
- anything else — `onBail()` fires first (it pops the scope and clears
  the owner's state), then the command dispatches normally
  (execute-through).

Commands the scope *owns* (registered on it) never trigger `onBail`;
its own bail verb pops explicitly. The interception lives in `invoke`,
so it governs mouse and programmatic invokes too, not just keys.

Three scopes are spring-loaded today: region mode (the `\` verb),
arrange's Shift+arrow selection band, and arrange's replace mode.

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

`cmgr:lastCommand()` returns the name of the last command body to run
and a serial counting the bodies run, both written just inside the
reachability gate, so an unknown name or one the stack blocks changes
neither. There is no after-any-command hook, so view state that should
last exactly one command anchors to the serial and compares it back
later, reading the name for the commands it lets pass; the tracker's
mini-map raise is the first consumer (`docs/trackerRender.md`
§ Palette tabs).

## Prefix capture

Prefix-argument entry is digit-only and gated. The dispatcher feeds
`'0'..'9'` and `'/'` into `appendPrefix` only while `isPrefixActive()`
is true, and the sole `beginPrefix` binding is Super+U (continuum.lua).
Bare digit keys therefore stay free for ordinary commands in any scope;
they collide with prefix entry only just after Super-U. There is no
letter-chord support — vim-style two-key entry (`gr`, `gg`) would need
new machinery.

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

## Binding-edit queries

`commandAtKey(spec, exceptName, ImGui)` answers "what reachable command
would this chord clobber?" — used by the help overlay before a rebind.
`bindingSite(name)` answers "which scope do I edit this command's binding
in?" Both walk the same stack reachability that `invoke`/`keychain` use,
so a hidden lower binding is neither a conflict nor an edit site.

A generated family is edited whole. `rebindFamily(family, mods, ImGui)`
rewrites every member to its base token under `mods`, keeping whatever
modifiers the base itself carries. `familyVictim(family, mods, ImGui)`
names the first chord that mask would claim from elsewhere, counting a
chord two members would come to share; the family's own current chords
are not in the way, since the rebind vacates them. A mask naming a
victim is refused rather than rebinding part of the family.

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
