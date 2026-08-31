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

## The `OPEN` sentinel

`util.OPEN` marks a note's `endppqL` as *deliberately unbounded* — a
freshly-placed legato note with no authored ceiling — as opposed to
`endppqL == nil`, which means *uncached* (foreign-MIDI import; derive
the tail from raw). Collapsing those two meanings into one nil was the
bug it exists to kill: a re-author path (shiftEvents, paste, gm)
cloning a note already clipped by a blocker re-stamped the clip as
intent, and the note could never regrow. Openness as a *value of*
`endppqL`, not a parallel `open` flag, makes the rule uniform —
`endppqL` present (finite or `OPEN`) is authoritative intent, never
overwritten from a realised clip.

Unlike `REMOVE` (a unique table, identity-compared, transient), `OPEN`
is `math.huge` — a persisted *value* of `endppqL`, and a number like
any other ceiling. Arithmetic on an open tail then just works: `inf +
finite` is `inf`, `inf > finite` is true, `math.min(inf, src)` is
`src`. Callers compare against `OPEN` to say they mean an open tail,
not to keep one out of a sum.

`tostring` of a non-finite float is platform-dependent, so both disk
formats pin the wire form themselves: `serialise` writes the literals
`inf` / `-inf` / `nan`, `prettySerialise` the arithmetic forms `1/0`,
`-1/0`, `0/0` (which need no environment to load).

## Serialisation format

`util.serialise` / `util.unserialise` implement a custom escaped format
used for note metadata (via `mm`) and config persistence (via `cm`).
Not JSON, not Lua syntax:

- `{k1=v1,k2=v2}` for tables.
- strings/numbers/booleans are unquoted; scalars decode back to their
  original type (numbers via `tonumber`, literals `true`/`false`).
- the four delimiter chars `{ } , =` plus `\` itself are backslash-escaped.
- control bytes (`< 0x20` and `0x7F`) are `\xHH` hex-escaped. The wire form
  is persisted via REAPER's C-string ext-state API, which truncates at the
  first NUL — and `util.key` joins composite keys with `\0`, so such a key
  would silently lose its tail without this. The format carries no raw
  control byte.
- cycles raise.
- trailing characters after a complete value raise.

Parse failures at callsites are caught and treated as empty tables; the
serialise side is strict.

Two formats coexist because the two paths want different things. P_EXT and
projext are the machine's hot path: `serialise` is compact and costs no
`load()` per write, and nothing hand-edits it. The disk files
(`continuum-config.lua`, `continuum-data.lua`) are the human's cold path:
`prettySerialise` writes a Lua table literal that `load()` reads, so
comments, whitespace and trailing commas come free. Neither form ever sits
in the other's store, so neither constrains the other.

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

`util.sortByPPQ` puts a list into that order. Ties are left where the sort
leaves them, so a list whose equal onsets need an order of their own carries
its own comparator — trackerManager's note columns interleave notes and PAs
that way.

`util.firstAfter` and `util.firstAtOrAfter` answer the same question by
bisection, and answer it as an index rather than an item: the first index
whose ppq passes the target, or one past the end when none does. Callers
read `firstAfter(list, ppq) - 1` as the last index at or before ppq, and 0
as "nothing before it". The pair differ only across a run of equal ppq,
which one opens and the other closes.

## Conventions

- **`clone` is shallow; `deepClone` is recursive.** `clone(src, exclude)`
  drops keys present in the `exclude` set — used by mm accessors to strip
  the `loc` slot before returning copies.
- **`picker` compiles a key list once**, where `pick` re-parses its key
  string per call. Both spellings stay: a cold site reads better with a
  space-separated string, and a hot one pays milliseconds a rebuild in
  `gmatch` for that reading. The closure owns the compiled list, so util
  keeps no module-level mutable state.
- **`snapTo` moves at least one interval.** A value already on a boundary
  advances by a full step — callers never get a no-op snap.
- **`nudgedScalar` is the canonical "arrow key" combinator.** Integer
  unit step without an interval, snap-to-next with one, clamped either way.
- **`setDigit` writes one digit in place** — digit `d` at place `pos`
  in `base`, clearing the places below it unless `keepBelow`. The grid's
  shift-held entry gesture passes `keepBelow` to overwrite a single
  place and stay on the row.
- **`dotimes(n, v)` overloads on type** — function `v` means "call n
  times for side effect"; anything else means "build an n-array of v".
