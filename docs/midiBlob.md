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

The key packs as `ppq*1e6 + rank*1e5 + seq2`. `ppq` is bounded below 2^31 by the
`i4` delta field it is packed into, so the composed key stays exact under 2^53
(the double-integer range). `seq2` is the event's mm slot doubled, with `+1`
reserved for a bezier tail so its CCBZ rider sorts immediately after its parent
cc at the same ppq/rank. `chunkOf` inverts the packing: `rank = (kv // 1e5) % 10`
selects the stream, `(kv % 1e5) // 2` the slot, and an odd `seq2` marks the rider.
Texts (rank 3) and passthrough (rank 4) are still dense arrays rebuilt per flush,
so for those two the slot is just the array index.

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

Two consequences worth knowing. The key's digit banding puts a hard bound on the
slot: `seq2 = slot*2` shares the 1e5 band with `rank`, so a slot must stay under
49999. Free-list reuse bounds slots by peak live event count, which is the same
bound the old dense index carried. And among events at one ppq the wire order is
now slot order, which after free-list reuse need not match the model's array
order — deliberately, per `design/stable-slots.md` § Equal-ppq order. Which of
two coincident events REAPER receives first is nothing to REAPER; the model side
still obeys the add-after-equals rule.
