# Design — reaper_eval bridge (live-REAPER MCP tool)

Status: implemented — S1–S4 landed. docs/bridge.md carries the durable model.

The one-line pitch: **an MCP tool that executes a Lua chunk inside the
running Continuum instance and returns the rendered result** — closing
the fake/real gap that every painful REAPER discovery has come
through (SetAllEvts playback stranding, GetTrackStateChunk cost,
PCM_Source_GetPeaks layout, harness take round-trip drops).

Static navigation is covered (map_query), batch reading is covered
(multiread/multigrep), harness tests are covered (lua_test_run). The
remaining gap is *observing the real thing*: when harness and REAPER
disagree, the loop today is hypothesise → ask Richard to alt-tab →
report back. This tool makes that loop one call.

## The load-bearing constraint

Each ReaScript runs in its own Lua state. A sibling script could call
`reaper.*` but could never touch the live manager stack — `tm`, `mm`,
`cm` are locals in Continuum's universe. So the bridge **must live
inside Continuum's own defer loop**, and the transport must be
something an external process can reach: files. (ExtState — the
existing `coord:onExternalCommand` transport — is only writable from
inside REAPER.)

```
Claude ─reaper_eval(code)→ server.py ─req file→ spool/ ←per-frame poll─ bridge.lua
       ←rendered result──           ←res file──                    (in Continuum)
```

## Protocol

Spool dir: `.claude/mcp/reaper/spool/` (gitignored). One request in
flight at a time — the MCP server enforces it, so file naming stays
dumb. Both sides write atomically: `.tmp` then rename.

**Request** — `req-<id>.lua`. Content is the raw Lua chunk, with
optional directive lines at the top, stripped before `load`:

```lua
--#undo transpose selection up   ← wrap in Undo_BeginBlock/EndBlock2, this label
--#depth 6                       ← serializer depth override (default 4)
return tm:cursor()
```

Directives keep the request one plain-Lua file — no JSON on the Lua
side, trivial to emit from Python.

**Response** — `res-<id>.txt`, line-framed so Python parses with
`partition`, not a parser:

```
status: ok            (or: error)
ms: 3.2
--- value ---
{ row = 12, track = 3 }
--- print ---
anything the chunk print()ed
```

On error the value section carries message + traceback. The bridge
deletes the request *before* executing, so a crash mid-chunk cannot
replay it; the server's timeout covers that case.

## bridge.lua (~100 lines, repo root)

Closures-over-state, `util.instantiate('bridge', { env })`. Three
parts:

- **tick()** — once per frame. Implicit opt-in: if the spool dir
  doesn't exist, no-op (existence re-checked every ~60 frames — one
  cached stat when idle). The MCP server creates the dir on startup,
  which switches the bridge on. When enabled: execute at most one
  `req-*.lua` per frame.
- **execute(chunk)** — parse directives, `load(code, 'bridge', 't',
  env)`, run under the bridge's **own** `xpcall` with
  `debug.traceback`. That xpcall is load-bearing: a bad chunk must
  never take down Continuum's defer loop. Executes at the
  coordinator's `tick()` point — before the page draws, REAPER API
  legal, state quiescent.
- **render(value, caps)** — bridge-local serializer, *not*
  `util.prettySerialise` (which targets round-tripping, not rendering
  cyclic userdata-laden manager tables). Survives cycles, renders
  userdata/functions via `tostring`. Caps: depth 4, 40 entries per
  table (`… +N more`), 200 chars per string, 64KB total. `env.print`
  appends to a per-request buffer.

## The eval environment

Curated table, not `_G` — every Continuum module is a `local` in its
own chunk, so nothing is reachable via globals anyway; the env *is*
the exposure surface:

```lua
env = {
  reaper = reaper, util = util, print = <buffered>,
  cm = cm, ds = ds, eventMeta = eventMeta, cmgr = cmgr, coord = coord,
  facade = function(name) return coord:getFacade(name) end,
  page   = function(name) return debugHandles[name] end,  -- page('tracker').tm
}
```

`debugHandles` is a small parallel to the facade registry: a page may
publish its raw stack for diagnostics. First customer is trackerPage —
`{ mm, tm, gm, ccm, pa, tv, tr }`. This is a deliberate, labelled hole
in the layering rule: facades remain the curated production surface;
`page()` exists only for the bridge and its annotation says so. Other
pages publish when a third real need appears, not before.

## Wiring

The coordinator hosts the bridge — constructed like
`chrome`/`modalHost`, ticked from the existing per-frame `tick()`. The
coordinator already owns the `STD` handle set and the facade registry,
so the env falls out of what it holds; zero new plumbing through
`continuum.lua`.

Rejected: hosting in `continuum.lua` via a new `coord:run` onFrame
callback (a seam with exactly one client); a parallel defer chain
(doubles lifecycle surface, survives nothing extra — an erroring frame
ends the script either way).

## server.py (~80 lines, `.claude/mcp/reaper/`)

Same idiom as `readium_tests`: uv script header, FastMCP,
`extra='forbid'` on ArgModelBase. One tool:

```
reaper_eval(code: str, timeout_s: float = 5,
            undo_label: str | None = None, depth: int | None = None) -> str
```

Creates the spool dir, sweeps stale files, writes the request
atomically, polls at 50ms, returns the response verbatim. Timeout →
`"no response after 5s — is Continuum running in REAPER?"`. Registered
in `.mcp.json` as `reaper`.

The tool description carries the safety contract:

- confirm before destructive chunks; pass `undo_label` for any mutation
- after raw `reaper.*` edits to the bound take, call
  `coord:reloadAfterExternalMutation()` (mutations through `mm`/`tm`
  fire hooks normally and need nothing)
- chunks must terminate — a hung chunk freezes REAPER's UI thread, no
  remedy from outside
- no ImGui calls — chunks run outside the draw pass

## Hazards, named

- **File-eval is an execution surface**: anything that can write to
  `spool/` executes code inside REAPER. Local dev tool, gitignored, no
  network listener; acceptable, but stated.
- **Hung chunk = frozen REAPER** (above). The server can't kill it.
- **Half-written responses**: prevented by tmp+rename on both sides.
- **Continuum not running**: server timeout with a clear message; no
  heartbeat file in v1 (add one only if the 5s wait proves annoying).

## Testing

`tests/specs/bridge_spec.lua` against a temp spool dir and a stub env —
the executor and protocol are pure file I/O + `load`/`xpcall`,
harness-testable as-is. Pins: request→response round trip, error path
with traceback, directive parsing, render caps (cycle, userdata,
per-table truncation, total cap), request deleted before execution.
Only the tick cadence needs the live frame loop, and that's one line.
The Python side is smoke-tested live (S3).

## Commit slices

Each slice lands green and committable on its own.

- **S1 — bridge core.** `bridge.lua` (directives, execute, render,
  spool poll) + `tests/specs/bridge_spec.lua` + `tests/run.lua`
  registration. Not yet wired into the app; pure harness work.
- **S2 — wiring.** `coordinator.lua` constructs the bridge and ticks
  it; `debugHandles` registry; `trackerPage.lua` publishes its stack.
  Suite stays green; bridge dormant until the spool dir exists.
- **S3 — MCP server.** `.claude/mcp/reaper/server.py`, `.mcp.json`
  registration, `.gitignore` spool entry. Live smoke test in REAPER:
  read a cursor, mutate under an undo label, error path, timeout path.
- **S4 — docs + polish.** `docs/bridge.md` (the WHY: single-Lua-state
  constraint, protocol rationale, the `page()` layering exception,
  hazards), `--KIND:` annotations settled, tool-description safety
  contract refined against real use.
