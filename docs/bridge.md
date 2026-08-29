# bridge

Live-REAPER eval bridge. An external process writes a Lua chunk into a
spool directory; the bridge — ticked from the coordinator's per-frame
`tick()` — executes it inside the running Continuum instance and writes
back a rendered result. The client is the `reaper` MCP server
(`.claude/mcp/reaper/server.py`), whose one tool `reaper_eval` makes
"observe the real thing" a single call when harness and REAPER disagree.

For task-oriented recipes (read state, add/edit/delete notes, units),
see `docs/bridge-cookbook.md`; this file is the model behind them.

## Why in-process, why files

Each ReaScript runs in its own Lua state. A sibling script could call
`reaper.*` but could never touch the live manager stack — `tm`, `mm`,
`cm` are locals in Continuum's universe, reachable from nowhere else.
So the bridge must live inside Continuum's own defer loop, and the
transport must be something an external process can write: files.
ExtState — the existing `coord:onExternalCommand` transport — is only
writable from inside REAPER, and rules itself out.

Chunks execute at the coordinator's tick point: before the page draws,
REAPER API legal, manager state quiescent, and no ImGui frame open —
which is why ImGui calls are banned in chunks.

## Protocol

Spool dir: `.claude/mcp/reaper/spool/`, gitignored. Request
`req-<id>.lua` is plain Lua with optional leading `--#` directives
(`--#undo <label>`, and any render cap `--#depth N` / `--#str N` /
`--#entries N` / `--#total N`) stripped before `load`; response
`res-<id>.txt` is line-framed. Both choices keep the parsers trivial:
no JSON on the Lua side, and Python splits the response with
`partition` rather than a parser.

Three properties carry the protocol's safety:

- **Atomicity.** Both sides write `.tmp` then rename, so a half-written
  file is never visible under its real name (and the `.tmp` suffix
  can't match the bridge's `req-*.lua` glob).
- **Isolation.** Request ids are uuid-keyed by the server, so
  concurrent tool calls touch only their own req/res pair; the bridge
  still serialises execution at one request per frame.
- **No replay.** The bridge deletes the request *before* executing it,
  so a chunk that kills REAPER mid-execution cannot re-fire on restart.
  The server's timeout covers the resulting silence.

## Enable gate

The bridge is dormant until the spool dir exists; the MCP server
creates it at startup, which switches the bridge on for good. Idle
cost while dormant is one stat per ~60 frames.

## The eval environment

The env is a curated table, not `_G`. Every Continuum module is a
`local` in its own chunk — nothing is reachable via globals anyway — so
the env *is* the exposure surface. A `__index = _G` fallback supplies
the stdlib and `reaper` without widening it, and chunk global writes
land in the env table, not `_G`, so a stray global in a chunk can't
leak into Continuum.

`page()` is a deliberate, labelled hole in the layering rule. Facades
remain the curated production surface; `page(name)` returns the raw
stack a page published via `facade.publishDebug` — trackerPage's
`{ mm, tm, gm, ccm, pa, tv, tr }` and wiringPage's `{ rm, wm, wv }`
are the only customers. The hole exists only for the bridge; a page
publishes when a real diagnostic need appears, not before.

## Rendering

`render` is bridge-local, not `util.prettySerialise`. Pretty-serialise
targets round-tripping — feed its output back to `load` and get the
value back — which is exactly wrong for manager tables: they are
cyclic and userdata-laden, and the bridge's job is a *view*, not a
value. So render marks cycles, renders userdata and functions via
`tostring`, and caps every axis — depth, entries per table, string
length, total bytes — so `return tm` is a safe thing to type. Each cap
is per-request overridable with a `--#<cap> N` directive (e.g. `--#str
4000` to widen the 200-char string cut when dumping a chunk). `print`
inside a chunk is redirected to a per-request buffer and returned as
the response's print section.

## Undo and the mutation watcher

Tick-time execution sits outside the draw-time bracket trackerPage's
external-mutation watcher was built around, and first live use found
the seam: a chunk mutating through tm under an undo label moved the
take's hash before the next frame's check, the watcher read its own
stack's write as foreign and reloaded from REAPER, and the re-read
cleared the pending undo capture before the defer cycle yielded — the
labelled undo block finalised empty (the 2026-07 bridge-undo
incident). The fix lives on the mm/page side: mm fires `flushed` after
every self-write reprojection and the page resyncs its hash baseline
instead of reloading. See `docs/trackerPage.md` § External-mutation
watcher.

Residue: a raw `reaper.*` edit to the bound take still needs
`coord:reloadAfterExternalMutation()`, and that explicit reload wipes
the chunk's undo capture just the same. The tool description's safety
contract therefore steers anything that must be undoable through
mm/tm.

## Reload

`reaper_reload` restarts the whole instance, which is how an edit to
Continuum's source reaches the running program: every ReaScript run
gets a fresh Lua state, so re-invoking the action re-reads every
module. `set_action_options(1|2)` makes a re-launch of an
already-running script terminate it and start it again, and
`get_action_context` still names our own action from inside a deferred
frame — so the bridge finds the action itself, with nothing wired from
`continuum.lua`.

The relaunch tears the Lua state down mid-call, so it cannot happen
inside the chunk. `reload()` sets a flag and returns; `tick()`
relaunches on the *next* frame, by which time the response file is on
disk and the requester has its ack.

The waiting is the server's half. After the ack it leaves a second
request in the spool, which the old instance never scans — its next
tick relaunches instead — and the new instance answers on its first
tick. So the tool returns when Continuum is back up, not when the
restart was asked for; silence means the new instance died at load.
That ping returns `bootTime`, REAPER-clock at bridge construction, and
an unchanged value means the old instance answered: a relaunch that
silently failed, otherwise indistinguishable from success.

## Spawning

Reload needs a live instance to receive it, and nothing inside REAPER
polls the spool when Continuum isn't running. So `continuum_launcher.lua`
is a second, tiny script instance — started from REAPER's
`__startup.lua`, outliving every Continuum instance — which polls about
once a second for `spool/spawn.marker` and re-invokes Continuum's
action. Launching is all it does: it reads no project state and writes
nothing. Idle cost is one stat a second for as long as REAPER is open.

Two files carry what it cannot know. `spawn.marker` holds the request's
epoch seconds, so a marker planted while REAPER was closed starts
Continuum on the next launch, but is discarded after a minute rather
than firing as an instruction from days ago. `spool/action.id` holds
Continuum's *named* command id, recorded by the bridge whenever it
enables: the numeric id is per-session, and the launcher has to know
what to start at the one moment when no instance exists to ask. The MCP
server's spool sweep spares that file for the same reason.

So `reaper_reload` means "a fresh Continuum is running when this
returns": it restarts a live instance, or, when nothing answers, plants
a marker and waits for the launcher's instance to come up.

## Claiming REAPER

One REAPER runs, and it loads Continuum through one symlink —
`Scripts/Continuum`, pointed at a tree. Sessions work in separate
worktrees, so that link decides which tree is live, and `reaper_reload`
repoints it at the calling session's tree before asking for anything.
Claiming is the reload; there is no second protocol to remember.

The link does more than choose the code for the next launch. `bridge.lua`
derives its spool directory from the path it was loaded from and never
resolves it, so the string it re-stats each tick *is* the link — a
running instance follows a repoint on its next frame, with nothing told
and nothing restarted. The launcher works the same way. So one `rename`
moves the code and the spool together, and there is no moment when the
link points nowhere.

What the other sessions get is silence, not error. Their requests land in
their own tree's spool, which nothing polls: a session that does not hold
the link cannot reach REAPER, and cannot reach it by accident either.
`reaper_eval` reads the link when it times out, because "loaded from
another tree" and "not running at all" are otherwise the same
observation.

`action.id` is the exception to per-tree spool state. It names an action
registered against a script path that never changes, so it is a fact
about the REAPER install; a claim seeds it from the outgoing tree when
the incoming one has none. Without that, a fresh worktree could restart
a live Continuum but never start a dead one.

SessionEnd hands the link back to the main tree, and only if the ending
session still holds it — otherwise whichever session finishes first
takes REAPER from one still using it.

That handback does not always run. A `claude --worktree` session deletes
the worktree hosting the hook before SessionEnd fires it, so an ordinary
exit can leave the link naming a tree that no longer exists. Continuum
then stops starting at all, and quietly: the action and `__startup.lua`
both reach it through the link, and the latter is guarded on the file
existing so that a moved repo raises no dialog. A claim therefore records
the main tree in `Scripts/Continuum.home`, beside the link, before it
moves anything. `__startup.lua` reads that file when the launcher is
unreachable and repoints the link before loading it. Running at every
REAPER launch and living outside the link, it is the only place the
repair can happen with no session left to ask. It is tracked in the repo
and symlinked into REAPER's `Scripts` directory, and that symlink names
the main tree directly: reaching it through `Scripts/Continuum` would
break the repair along with the link it repairs.

## Hazards

- **File-eval is an execution surface.** Anything that can write to
  `spool/` executes code inside REAPER. Acceptable for a local dev
  tool — gitignored, no network listener — but stated.
- **A hung chunk freezes REAPER.** Chunks run on REAPER's UI thread;
  nothing outside can kill one. The server's timeout ends the waiting,
  not the chunk.
- **Continuum not running** is indistinguishable from a slow chunk:
  the server times out with a message naming the likely cause. It can
  rule one cause in without asking REAPER anything — a link pointing at
  another tree is visible from outside. No heartbeat file in v1 — add
  one only if the 5s wait proves annoying.

## Testing seam

The executor and protocol are pure file I/O plus `load`/`xpcall`, so
`tests/specs/bridge_spec.lua` drives them against a temp spool dir and
a stub env; only the tick cadence needs the live frame loop. The
Python side is smoke-tested live against REAPER.
