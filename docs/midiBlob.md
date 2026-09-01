# midiBlob

WHY notes for the blob codec. Surface, shapes, and invariants live in
`midiBlob.lua` and its `--shape:`/`--invariant:` annotations.

## buildWire / render: bare-integer sort keys

The write path is a pair. `buildWire` packs each event into a single integer sort
key rather than a `{ppq, rank, seq, flags, msg}` table, sorts those keys, and
regenerates the wire bytes from `chunkOf` into a `chunks` array parallel to them;
`render` concatenates the chunks and places the EOT tail. Two payoffs from keying
on bare integers:

- **No per-event tables.** The build loop stores only numbers, so it allocates
  nothing beyond the `keys` array itself.
- **C-level sort.** A plain number array sorts under `table.sort`'s default
  comparator (C), avoiding a Lua comparator closure invoked ~40ns/call over the
  ~180k compares a dense take produces.

The key packs as `ppq*1e9 + rank*1e8 + seq2`, written in the source as integer
literals — `1000000000`, not `1e9`, which is a *float* in Lua 5.4 and would make
the whole composed key a float. That distinction is what the headroom rests on.
Every ppq reaching the wire is integer-**typed** (`tm:fromLogical` ends in
`util.round` → `math.floor`; `parse` unpacks an `i4`), so a key is a true int64
and its ceiling is 9.2e18 rather than the 2^53 a double would impose. `ppq` is
bounded below 2^31 by the `i4` delta field it is packed into, putting the largest
key near 2.1e18 — four times the headroom. A float `480.0` ppq would lose
exactness above 2^53 whatever the strides, which is why the typing matters and
not merely the magnitude.

`seq2` is the event's mm slot doubled, with `+1` reserved for a bezier tail so its
CCBZ rider sorts immediately after its parent cc at the same ppq/rank. `chunkOf`
inverts the packing: `rank = (kv // 1e8) % 10` selects the stream, `(kv % 1e8) //
2` the slot, and an odd `seq2` marks the rider.
Ranks separate the streams and settle the order of events sharing a ppq: 0
note-off, 1 note-on, 2 cc (an odd `seq2` marking its CCBZ rider), 3 note sidecar,
4 cc sidecar, 5 carried text, 6 passthrough. The sidecars take a rank each
because each keys on its *owner's* slot, and note slot 5 is not cc slot 5 — one
shared text rank would collide. Carried texts and passthrough are still dense
arrays rebuilt per flush, so for those two the slot is just the array index.

The split into two functions is what lets the wire state outlive the flush: mm
holds the `keys` and `chunks` arrays, so an edit can splice both and re-pack only
the chunks it touched instead of rebuilding every one. It also fixes which half
the pack loop belongs to — a chunk's delta comes from its predecessor key, so
packing is inherently a walk over the sorted keys, leaving `render` as concat plus
tail. `render` appends that tail as a transient last element of `chunks` and
clears it again, because `table.concat(chunks) .. tail` would copy the whole blob
to add twelve bytes.

## Why the slot and not the array index

The key used to be `index*2` over a dense ppq-ordered snapshot, which meant mm
had to gather two arrays per flush and every key died the moment anything moved.
A slot names one event for as long as it lives (see `docs/midiManager.md` §
Stable slots), so a slot key survives a flush — the precondition for holding the
key array across flushes and splicing only what an edit touched. It also lets mm
hand `buildWire` its live sparse tables directly; `buildWire` never mutates them.

A sidecar text rides its owner's slot for the same reason, and this is where the
argument bites hardest: a sidecar's own array position never was stable, because
`flushTake` rebuilds the list every flush. Under a dense text key one note added
anywhere renumbered every sidecar after it — up to ~10k of them on a dense take —
so the incremental path would have fallen back to full regeneration on exactly
the add/delete/move gestures it exists to make cheap.

Two consequences worth knowing. The key's digit banding puts a hard bound on the
slot: `seq2 = slot*2` shares the 1e8 band with `rank`, so a slot must stay under
5e7. Free-list reuse bounds slots by peak live event count, which is the same
bound the old dense index carried — and 5e7 is far past any of it. The first
scaling banded at 1e5, capping a slot at 5e4, which *was* reachable: `rebuildPbs`
writes a cc per QN, ~115k ccs in one stream over a thirty-minute take. Past the
cap two events compose the same key and one chunk silently overwrites the other,
so the fix had to be a wider key rather than a guard — falling back to full
regeneration rescues nothing when `buildWire` composes the same colliding key.
And among events at one ppq the wire order is
now slot order, which after free-list reuse need not match the model's array
order — deliberately. Which of two coincident events REAPER receives first is
nothing to REAPER; the model side still obeys the add-after-equals rule.

## Splicing a held wire

`putKey`, `dropKey` and `repackKey` are what a held wire is for: they maintain the
ascending `keys` array and its index-parallel `chunks` in place, so a flush pays
for the events an edit touched instead of re-keying and re-packing the take.

Each splice re-packs at most two chunks — its own and its successor's. A chunk's
delta is the gap from its *predecessor's* ppq, so inserting or removing a key
changes the delta of the key that now follows it and of nothing else. `repackKey`
re-packs one, because the key has not moved: it is the property edit (velocity,
value, mute), the commonest gesture there is, and drop-then-put of the same key
would reach the same bytes at the cost of two memmoves.

A bezier cc's CCBZ rider is inseparable from its cc by construction rather than by
rule: the rider's key is its cc's key `+1`, so no key can ever sort between them,
which is what keeps the rider's hard-coded zero delta valid under any splice.

The wire carries its own model. `buildWire` stashes the four tables it was handed
on the wire it returns, so a helper takes `(wire, kv)` and cannot be handed a model
the keys were not built from — the failure mode this rules out is silent and
byte-level. The cost falls on the caller, which must keep one grouped `texts` table
alive between full rebuilds rather than composing a fresh one per flush.

A helper returns `false` when the wire and the caller's dirt disagree — a key put
twice, or dropped when it was never there. Nothing is mutated, and the caller's
guard falls back to a full `buildWire`, because a disagreement means the dirt
record has lost track of the wire and no further splice can be trusted.

A splice is cheap per key but not free: `table.insert`/`table.remove` shift every
key past the one that moved, so `k` splices over an `n`-key wire cost `O(k*n)`
where `buildWire` costs `O(n)`. Measured, the two cross at a hundred-odd keys
whatever `n` is — the ratio is packing cost against memmove cost, and `n` cancels.
A gesture reaches that easily: deleting an fx note host takes every tile its chain
realised with it, which was 3585 keys and 212ms of splicing on a take whose whole
wire re-keys in 5. So `syncSlots` counts its structural changes first and declines
past `SPLICE_CAP`, before a single key moves. It says which — `'dense'` or
`'disagreed'` — because only the second is news about the wire's health.

`slotState` and `syncSlots` sit one level up, where a caller thinks in slots rather
than keys. `slotState` reads the wire's own model for the four fields that decide a
slot's key set — `ppq`, `endppq`, `shape`, and the sidecar row's `sidePpq` — so the
key format never leaves this file. `syncSlots` takes a before-snapshot of that same
shape per dirty slot, derives each slot's two key sets through one private helper,
and drops, puts or repacks accordingly; deriving both sides the same way is what
keeps them honest. A slot's key set is at most three, so membership is a linear
scan, and a velocity edit repacks three keys where one would do — microseconds
against the full re-key it replaces.

It takes the whole nest's dirt in one call, and that isn't convenience: sequencing
across slots is load-bearing. Mid-splice the wire transiently holds keys whose model
row is already gone — a deleted note's slot is nil in `notes` from the moment the
verb ran — and every put and drop re-packs its neighbour, so splicing one slot can
ask `chunkOf` to pack another slot's dead key and index a nil. Hence three phases.
Drops go first, in **descending** key order, so that when a key is removed every
dead key above it has already gone and the successor being re-packed is live. Then
puts, each of which re-packs a successor that is now certainly live. Then repacks,
last because a repacked chunk's delta is only final once every insertion before it
has landed. A failure at any phase returns immediately rather than pressing on: the
caller is going to regenerate anyway, and continuing would walk into the dead key
the failed drop left behind. Repacks don't count toward the cap: they move no key,
so they cost what they always did however many there are.

The sidecar key comes off the *row's* ppq rather than its owner's, even though the
caller keeps the two equal: the row is what `chunkOf` packs, so a row left stale has
to surface as a wrong key instead of being papered over by its owner's.
