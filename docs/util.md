# util

Shared utilities used across every manager. No state of its own — a grab
bag of the idioms that would otherwise be reinvented in each file.

## The `REMOVE` sentinel

`util.REMOVE` is a unique table used as a delete marker in field-wise
merges. `util.assign(t, {k = util.REMOVE})` clears `k` from `t`.

The same semantics is honoured by `mm:assignNote` / `mm:assignCC` /
`cm:assign` at their entry points — a caller building an updates table
can mix sets and deletes uniformly without a second code path.

REAPER-native boolean flags (`muted`) opt out: they clear by assigning
`false`, not `REMOVE`, because they are not metadata and the backend
has no "absent" state.

## Serialisation format

`util.serialise` / `util.unserialise` implement a custom escaped format
used for note metadata (via `mm`) and config persistence (via `cm`).
Not JSON, not Lua syntax:

- `{k1=v1,k2=v2}` for tables.
- strings/numbers/booleans are unquoted; scalars decode back to their
  original type (numbers via `tonumber`, literals `true`/`false`).
- the four delimiter chars `{ } , =` plus `\` itself are backslash-escaped.
- cycles raise.
- trailing characters after a complete value raise.

Parse failures at callsites are caught and treated as empty tables; the
serialise side is strict.

## Callback installation

`util.installHooks(owner)` is the shared signal-keyed listener protocol. It
installs three methods on `owner` and returns a `fire(signal, data)` closure:

```
owner:subscribe(signal, fn)        register a listener
owner:unsubscribe(signal, fn)      remove a listener
owner:forward(signal, source)      subscribe on `source`, re-fire on owner
                                   (source must also have installHooks)
```

Listeners are filtered by signal at registration: a callback registered for
one signal name never fires for another. `forward` is sugar for the common
"layer above passes a signal through unchanged" pattern.

mm, tm, and cm all use this — see each manager's doc for the signals it
emits.

## Event-list helpers

`util.seek` and `util.between` assume a ppq-sorted input array. `between`
uses half-open `[lo, hi)` intervals so adjacent windows tile without
double-counting. Both take an optional filter predicate, letting callers
restrict to note-ons, particular channels, etc. without a pre-pass.

## Conventions

- **`clone` is shallow; `deepClone` is recursive.** `clone(src, exclude)`
  drops keys present in the `exclude` set — used by mm accessors to strip
  `idx`/`uuidIdx` internals before returning copies.
- **`snapTo` moves at least one interval.** A value already on a boundary
  advances by a full step — callers never get a no-op snap.
- **`nudgedScalar` is the canonical "arrow key" combinator.** Integer
  unit step without an interval, snap-to-next with one, clamped either way.
- **`setDigit` supports half-step entry** via `half` — used by the
  shift-digit path in the grid.
- **`dotimes(n, v)` overloads on type** — function `v` means "call n
  times for side effect"; anything else means "build an n-array of v".
