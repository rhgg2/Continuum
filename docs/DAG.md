# DAG

## gainSinks — where a gained wire's volume lands

A folded gain on an audio wire lands either on the REAPER send that
carries it (as `mainSendGain`) or on a CU bridge synthesised for
unfoldable cases (cross-host, multi-pair). `ctx:gainSinks` is the
authoritative fold decision: it is computed once and shared by
`targetPlan` (which writes `outWires.gain` / `mainSendGain`) and
`wm:pokeEdgeGain` (which pokes the live value without a full
recompile).

## targetPlan shape — outWires, intraConns, masterFeed semantics

`outWires` are sends that leave a host. Each carries `from`, `to`,
`type`, and optionally `gain` (folded boundary gain) and `srcChan` /
`dstChan` (assigned by `M.allocate`). `intraConns` are FX-to-FX
connections within the same host: same fields but no channel
assignment. `masterFeed` is the single outWire entry that feeds the
master-hosted class; its `from` / `fromPort` identify the last node
before the boundary. When a master-hosted fx exists, its host's plan
output feeds the host's parent send to the master-hosted host; the
allocator pins that output and stamps `mainSendOffs`. Folded boundary
gains carry their value on `outWires.gain` / `mainSendGain`, not a
CU. `M.allocate(targetPlan)` turns `outWires` into sends with
per-tuple channel assignment.

## Split markers — a node as its own source

`node.split` (fx-only; `M.validate` refuses it elsewhere) makes a node
seed `'split:'..id` into its own `srcSet`. The tag propagates forward
like any source contribution, so the node and its downstream cone land
in their own equivalence class — their own REAPER track — and the cut
edge into the marked node becomes a send. A split-tagged class never
absorbs (`ctx:absorption`); otherwise its single-parent cone-top would
fold straight back. This is the per-node sibling of an edge's `primary`
override and what the (deferred) manual split-at-a-node gesture writes;
Stage 3b's master-minimization computes the same markers. A cone that
is the sole contributor to master re-merges into master's class (no
eviction) — audibly identical, and the correct "least eviction"
outcome. The split tag rides class keys (and thus the `wiringClass`
ownership string) as an opaque, stable segment; nothing downstream
parses it.

## Master-minimization — evicting fx that need two master pairs

`master.audio.ins = 1` means each contributing track reaches the master
through one parent send: one stereo pair. So a master-hosted fx can pull at
most one pair from any single upstream host. An fx fed ≥2 audio input ports by
the *same* host needs two pairs from one parent send — unrepresentable. (Two
ports from two *different* hosts is fine: main on one parent send, sidechain on
another.)

`ctx:masterSplits` (run by `M.compile` on every compile, unioned into `srcSet`
alongside persisted `node.split`) resolves this by eviction. For each violating
fx it derives a split marker at the fx's **immediate post-dominator toward
master** — the nearest node every path from the fx to master crosses. Marking
that node taints master with its `split:` tag while the violator, strictly
upstream, stays untagged and peels onto its own track, where ordinary
multi-pair sends feed it and it parent-sends one pair up. The post-dominator is
the largest single-entry cone that still excludes the violator, so it is the
least-eviction cut. If the fx reaches no sink, it splits itself (the self-tag
is re-merge-safe — master never inherits it).

A fixpoint repeats — evicting one fx can expose a fresh violator downstream,
whose marker lands strictly closer to master — until the master class is
violation-free. It always converges: the inward terminus is a derived split on
the master node itself (`C_m = {master}`), reached when a violator's paths to
master rejoin only at master. Markers move rather than accumulate: a marker
with another marker downstream is pruned, since the inner cut already evicts
everything above it.

## CU bridge invariant — edge ops and folding

An edge's gain/channelMap op rides the edge as metadata. The CU
bridge synthesised for an unfolded gain carries `originEdgeIdx` so the
applier can stamp `opFxGuid` back via `wm:mutate` after
`TrackFX_AddByName` succeeds. `channelMap` never folds onto a send
because sends carry no remap capability. `ctx:gainSinks` is the
authoritative fold decision shared by `targetPlan` and
`wm:pokeEdgeGain`.

## synthNode field roles

Each `synthNode` is a CU bridge synthesised for one of three cases:

- **Wire-level op** (`originEdgeIdx` set): cross-host audio gain or MIDI
  `channelMap` that cannot fold onto a send. The edge index lets the applier
  write `opFxGuid` back after `TrackFX_AddByName`.
- **Bus-swap bracket** (`originNode` / `originSide` set): a CU inserted at the
  in- or out-side of a node to reorder bus pairs. See `design/wiring.md § 3c`.
- **Per-consumer audio merge** (`originConsumer` / `originHost` / `inputEdges`
  set): one Merge CU per (consumer, host) pair; `inputEdges` maps each input
  pair back to its edge for live-gain pokes.

## per-consumer merge

For each FX, intra-host audio feeders are gathered; for each host, master-bound
feeders are gathered. All-unity ⇒ matrix-fed directly (no CU needed). Any
non-unity gain ⇒ one Merge CU spanning every feeder, with the unity ones at
1.0 and the gained ones at their value; a single gained feeder is the degenerate
`nPairs=1` case. Identity is per `(consumer, host)` via `node.mergeGuids`;
`inputEdges` maps each pair index back to its originating edge for
`wm:pokeEdgeGain`. (>16 feeders into one FX exceeds CU channel width — a
deferred capacity concern. See `design/wiring.md § Merge` for the format.)

Feeders reduce to fit the summing model. A *unit* groups one consumer's feeders
on one host. Normal FX (and intra-master) consumers reduce at the consumer host.
For a producer on a different host, the width-1 parent send forces a pre-sum, so
the Merge CU sits on the producer host and its output is the send source.
