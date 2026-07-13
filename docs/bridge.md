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
(`--#undo <label>`, `--#depth N`) stripped before `load`; response
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
length, total bytes — so `return tm` is a safe thing to type. `print`
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

## Hazards

- **File-eval is an execution surface.** Anything that can write to
  `spool/` executes code inside REAPER. Acceptable for a local dev
  tool — gitignored, no network listener — but stated.
- **A hung chunk freezes REAPER.** Chunks run on REAPER's UI thread;
  nothing outside can kill one. The server's timeout ends the waiting,
  not the chunk.
- **Continuum not running** is indistinguishable from a slow chunk:
  the server times out with a message naming the likely cause. No
  heartbeat file in v1 — add one only if the 5s wait proves annoying.

## Testing seam

The executor and protocol are pure file I/O plus `load`/`xpcall`, so
`tests/specs/bridge_spec.lua` drives them against a temp spool dir and
a stub env; only the tick cadence needs the live frame loop. The
Python side is smoke-tested live against REAPER.
