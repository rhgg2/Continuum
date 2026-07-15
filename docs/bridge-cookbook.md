# bridge — cookbook

Task-oriented recipes for the `reaper_eval` MCP tool. `docs/bridge.md`
is the *why* (protocol, env, undo seam); this is the *how* — the calls
you keep rediscovering. Recipes below are verified against a live
Continuum; paste them into the tool's `code` arg.

## The model in one breath

One tool, `mcp__reaper__reaper_eval`, ships a Lua chunk to the running
Continuum and renders what you `return`. The chunk runs at the
coordinator tick: REAPER API legal, manager stack quiescent, **no ImGui
frame** (ImGui calls are banned). Load the schema once per session
(`ToolSearch select:mcp__reaper__reaper_eval`) before the first call.

Env handles (curated locals, not `_G`):

| handle | is |
|---|---|
| `reaper`, `util` | REAPER API + shared helpers |
| `cm`, `ds`, `eventMeta`, `cmgr`, `coord` | config, dataStore, eventMeta, commandManager, coordinator |
| `facade(name)` | curated production facade for a page |
| `page(name)` | raw page stack — `page('tracker') = { mm, tm, gm, ccm, pa, tv, tr }` |
| `print(...)` | buffered into the response's print section |

`return <expr>` to see a value; the renderer is cycle-safe, caps every
axis, and prints userdata via `tostring`, so `return tm` is safe to
type. Bump `depth` (default 4) for deeper tables.

Almost every tracker recipe opens with the same handle grab:

```lua
local p = page('tracker'); local mm, tm = p.mm, p.tm
```

## Units and frames

- **ppq** is the only time unit. `mm:resolution()` is ppq-per-quarter
  (12288 on the test project), so a 4/4 bar = `4 * resolution` ppq
  (49152). `mm:length()` is the take length in ppq.
- **Two frames.** `tm` speaks *logical* ppq (what you see in the
  grid, pre-swing/pre-delay). `mm` holds *raw* realisation ppq (swing
  applied, delay baked into the note-on). Author through `tm` and you
  stay in the frame a human edits; drop to `mm` and you owe the
  translation yourself. Convert with `tm:fromLogical(chan, ppqL)` /
  `tm:toLogical(chan, ppqRaw)`.
- pitch/vel ∈ 0..127, chan ∈ 1..16, `endppq` is the authored ceiling
  or `util.OPEN` for an open tail.

## Reading state (safe — no mutation)

Snapshot the take:

```lua
local p = page('tracker'); local mm = p.mm
return { name = mm:name(), length = mm:length(), resolution = mm:resolution(),
         timeSigs = mm:timeSigs() }
```

First few notes (clones, safe to inspect):

```lua
local p = page('tracker'); local out = {}
for tok, n in p.mm:notes() do
  out[#out+1] = { chan=n.chan, pitch=n.pitch, vel=n.vel, ppq=n.ppq, endppq=n.endppq }
  if #out >= 5 then break end
end
return out
```

`mm:notes()` / `mm:ccs()` yield cloned records; `mm:events()` yields
`(token, clone)` when you need the **token** to edit or delete.
`mm:notesRaw()` is the uncloned fast path — read only, never mutate.

Rendered channel columns (post-rebuild, logical-frame, view-ready):

```lua
local p = page('tracker'); local ch = p.tm:getChannel(2)
return ch and ch.columns.notes
```

Edit-cursor position in ppq: `p.tm:editCursor()`.

## Profiling a rebuild

`perf` (the nested profiler) isn't an env handle, but every Continuum
module is a cached `require`, so `require('perf')` hands back the *same*
singleton the app uses. Wrinkles that make a naive read wrong:
`perf.report()` no-ops unless `perf.on` (armed live with Ctrl+Shift+P);
it emits through `util.print` — REAPER's console, not the chunk's
redirected `print` — so you must swap that sink to capture it; and GC
(~20ms) plus a cold first frame inflate any single run, so
`collectgarbage('collect')` first and **discard run 1**. A bare
`tm:rebuild` runs the pipeline *outside* any span, scattering its stages
as throwaway roots; wrap it in your own root span.

There are **three baselines** — distinct pipeline paths that do not move
together. Measure all three; each `[perf] <indented stage> <ms>` tree is
sorted within itself by cost.

### 1. Import — the foreign-MIDI bind (`externals`-dominated)

A genuine import has no uuids and no metadata anywhere; mm mints
everything fresh. Dropping the eventMeta pool is *not* enough — sidecars
left in the blob still carry uuids and route the bind down the
*adoption* path, not first-contact. Tear the blob back to raw MIDI
(strip every 0xFF text + 0xF0 sysex event), drop the pool, then reload.
Destructive but repeatable: the bind re-stamps to state 2, so re-strip
for state 1 again. (Lane assignments are lost — reload the file to
recover the original voicing.)

```lua
local perf, util = require('perf'), require('util')
local mm = page('tracker').mm
local take, guid = mm:take(), mm:poolGuid()

local ok, blob = reaper.MIDI_GetAllEvts(take, '')
local pos, absppq, kept = 1, 0, {}
while pos < #blob do
  local offset, flag, msg, np = string.unpack('i4Bs4', blob, pos)
  absppq = absppq + offset
  local status = msg:byte(1) or 0
  if status >= 0x80 and status <= 0xEF then          -- channel-voice only
    kept[#kept+1] = { ppq = absppq, flag = flag, msg = msg }
  end
  pos = np
end
local out, last = {}, 0
for _, e in ipairs(kept) do
  out[#out+1] = string.pack('i4Bs4', e.ppq - last, e.flag, e.msg); last = e.ppq
end
reaper.MIDI_SetAllEvts(take, table.concat(out)); reaper.MIDI_Sort(take)
eventMeta:dropPool(guid)

collectgarbage('collect')
local lines, wasOn = {}, perf.on
local real = util.print; util.print = function(s) lines[#lines+1] = tostring(s) end
perf.on = true
perf.start('import'); coord:reloadAfterExternalMutation(); perf.stop('import')
perf.report()
perf.on = wasOn; util.print = real
return lines
```

The import tree is dominated by first-contact work absent from steady
state: `externals` (one uuid minted per note) plus a *doubled*
`serialise`/`setEvts`/`sidecars` writing all metadata out for the first
time.

### 2. Steady no-op — forced full re-derive (`internals`-dominated)

`rebuild(true)` re-derives every channel from the settled internal
columns — no mutation, `externals` is 0. Infinitely repeatable; the
forced-full ceiling the parity spec compares against.

```lua
local perf, util = require('perf'), require('util')
collectgarbage('collect')
local lines, wasOn = {}, perf.on
local real = util.print; util.print = function(s) lines[#lines+1] = tostring(s) end
perf.on = true
perf.start('probe'); page('tracker').tm:rebuild(true); perf.stop('probe')
perf.report()
perf.on = wasOn; util.print = real
return lines
```

### 3. Steady edit — one dirty channel (the maintenance path)

A one-note edit; `flush` self-reports its `flush → mm → reload → …`
tree. Self-revert to leave the take byte-identical, so it stays
repeatable without a reload. This is the path interval dirt narrows.

```lua
local perf, util = require('perf'), require('util')
local tm, mm = page('tracker').tm, page('tracker').mm
local function firstNote() for _, e in mm:events() do if e.evType == 'note' then return e end end end
local t = firstNote(); local orig = t.vel; local nv = orig == 100 and 99 or 100
collectgarbage('collect')
local lines, wasOn = {}, perf.on
local real = util.print; util.print = function(s) lines[#lines+1] = tostring(s) end
perf.on = true
tm:assignEvent(t.token, { vel = nv }); tm:flush()               -- MEASURED
perf.on = wasOn; util.print = real
local b = firstNote(); tm:assignEvent(b.token, { vel = orig }); tm:flush()  -- revert
return lines
```

## Swapping fixtures without reloading a project

The open ctm take is a scratch canvas: inject a raw-MIDI blob and the
take *becomes* that fixture, so you profile several fixtures in one
session without opening a project file. Works for MIDI-shaped fixtures
(the dense single-channel take); a macro/fx-heavy fixture also needs its
generator config, which a blob does not carry.

Capture the current take's raw MIDI — strip metadata so a later inject
reproduces the import→settle cycle (all three baselines from one blob).
The blob stores note-on and note-off as *separate* events, so its count
is ≈2× the model's note+cc count.

```lua
local mm = page('tracker').mm
local ok, blob = reaper.MIDI_GetAllEvts(mm:take(), '')
local pos, absppq, kept = 1, 0, {}
while pos < #blob do
  local offset, flag, msg, np = string.unpack('i4Bs4', blob, pos)
  absppq = absppq + offset
  local status = msg:byte(1) or 0
  if status >= 0x80 and status <= 0xEF then          -- channel-voice only
    kept[#kept+1] = { ppq = absppq, flag = flag, msg = msg }
  end
  pos = np
end
local out, last = {}, 0
for _, e in ipairs(kept) do
  out[#out+1] = string.pack('i4Bs4', e.ppq - last, e.flag, e.msg); last = e.ppq
end
local f = io.open('/abs/path/fixture.rawmidi', 'wb'); f:write(table.concat(out)); f:close()
return #kept
```

Inject a saved blob into the open take (this IS the import baseline; it
settles to state 2 afterward, so re-inject for a fresh import):

```lua
local mm = page('tracker').mm
local f = io.open('/abs/path/fixture.rawmidi', 'rb'); local raw = f:read('a'); f:close()
reaper.MIDI_SetAllEvts(mm:take(), raw); reaper.MIDI_Sort(mm:take())
eventMeta:dropPool(mm:poolGuid())
coord:reloadAfterExternalMutation()
return 'injected'
```

Clear the take with a terminal-only blob:
`reaper.MIDI_SetAllEvts(take, string.pack('i4Bs4', 0, 0, '\xB0\x7B\x00'))`.

## Writing — the golden rules

1. **Confirm with the user before any destructive chunk.**
2. **Pass `undo_label`** for *any* mutation so it lands as one named
   REAPER undo step.
3. **Route through `tm`/`mm`.** Their writes fire hooks and reproject
   the take; nothing further needed. A raw `reaper.*` edit does not
   (see below).
4. **The chunk must terminate** — it runs on REAPER's UI thread; a
   hang freezes REAPER with no outside remedy.

### Add a note (logical frame — the human path)

`tm:addEvent` stages; `tm:flush()` commits and rebuilds. Defaults fill
`detune=0, delay=0, lane=1`. `ppq`/`endppq` are **logical**.

```lua
local p = page('tracker'); local tm = p.tm
tm:addEvent{ evType='note', chan=1, pitch=60, vel=100, ppq=0, endppq=12288 }
tm:flush()
return 'added'
```
Call with `undo_label='add C4'`. If the project has swing, the raw
`endppq` you read back from `mm` may differ from your logical `12288` —
that is the logical→raw realisation, not a lossy write. With no swing
the two frames coincide.

### Edit a note

Stage an assign against the live event (it carries `.token`) or its
token, then flush. Get the event from a channel column or `mm:events()`:

```lua
local p = page('tracker'); local tm, mm = p.tm, p.mm
local token = select(1, mm:events()())   -- first event's token; or find yours
tm:assignEvent(token, { vel = 40, pitch = 62 })
tm:flush()
return 'edited'
```

Structural fields an assign accepts: `ppq, endppq, pitch, vel, chan,
muted, lane`. `muted=false` clears the flag.

### Delete a note

```lua
local p = page('tracker'); local tm, mm = p.tm, p.mm
local token = select(1, mm:events()())
tm:deleteEvent(token)   -- accepts an event table (with .token) or a bare token
tm:flush()
return 'deleted'
```

### Low-level, raw frame (`mm` direct)

When you deliberately want raw ppq and no logical translation, wrap the
writes in `mm:modify` — the required bracket for `add*`/`assign*`/
`delete*`; it reprojects the take once on unwind.

```lua
local p = page('tracker'); local mm = p.mm
mm:modify(function()
  local token = mm:add{ evType='note', chan=1, pitch=60, vel=100, ppq=0, endppq=12288 }
  mm:assign(token, { vel = 80 })
end)
return 'raw write'
```

`mm:add` returns the token; `mm:assign(token, t)` returns the possibly
re-keyed token (re-capture it if an identity field moved);
`mm:delete(token)` removes in place. All ppq here is **raw** — convert
from logical with `tm:fromLogical` first if you're placing by grid row.

### Take length

`tm:setLength(newPpq)`, `tm:rescaleLength(newPpq)`,
`tm:tileLength(newPpq)`. Route through `tm`, not raw EOT edits.

### Raw `reaper.*` edits to the bound take

Legal, but the tracker stack won't know: you **must** call
`coord:reloadAfterExternalMutation()` afterwards or `tm`/`tv` drift
from the take. That reload finalises the pending undo capture *empty*,
so `undo_label` is silently dropped on this path — which is exactly why
anything undoable goes through `tm`/`mm` instead.

## Gotchas

- **Tokens are per-rebuild.** A token is content-keyed and re-minted
  each rebuild; a `loc` is valid only within one rebuild-to-flush
  window. For a handle that survives rebuilds, use the note's durable
  `uuid` via `tm:byUuid(uuid)`.
- **`mm:modify` is mandatory for `mm` writes.** Calling `mm:add`
  outside it works in-memory but you lose the single-flush guarantee;
  `tm:flush()` handles this for you on the `tm` path.
- **No ImGui, ever.** The chunk runs outside the draw pass.
- **Timeout = likely "Continuum not running".** A 5s timeout with no
  response usually means Continuum isn't open in REAPER, not a slow
  chunk. Raise `timeout_s` only for genuinely heavy reads.
- **A bound take is assumed.** `page('tracker').mm:take()` returns the
  live take; recipes above no-op silently if nothing is bound.
