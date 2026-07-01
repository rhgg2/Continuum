# midiBlob

WHY notes for the blob codec. Surface, shapes, and invariants live in
`midiBlob.lua` and its `--shape:`/`--invariant:` annotations.

## serialise: bare-integer sort keys

`serialise` packs each event into a single integer sort key rather than a
`{ppq, rank, seq, flags, msg}` table, and regenerates the wire bytes at emit
time from `decodeWire`. Two payoffs:

- **No per-event tables.** The build loop stores only numbers, so it allocates
  nothing beyond the `keys` array itself.
- **C-level sort.** A plain number array sorts under `table.sort`'s default
  comparator (C), avoiding a Lua comparator closure invoked ~40ns/call over the
  ~180k compares a dense take produces.

The key packs as `ppq*1e6 + rank*1e5 + seq2`. `ppq` is bounded below 2^31 by the
`i4` delta field it is packed into, so the composed key stays exact under 2^53
(the double-integer range). `seq2` is `index*2`, with `+1` reserved for a bezier
tail so its CCBZ rider sorts immediately after its parent cc at the same
ppq/rank. `decodeWire` inverts the packing: `rank = (kv // 1e5) % 10` selects the
stream, `(kv % 1e5) // 2` the record index, and an odd `seq2` marks the rider.
