# DAG

Pure structural calculus for the wiring page. `M.compile` returns a
lazy-caching ctx; user-graph predicates are free-standing. For the
full wiring model see `design/wiring.md`.

## gainSinks — where a gained wire's volume lands

`ctx:gainSinks` maps each edge index to the sink where its volume is
applied. A gain on the sole wire realised as a send (track→track) or
the parent/master send folds onto that send's native volume
(`{kind='send'|'mainSend'}`); intra-class routing or several wires
collapsing onto one send keep a CU (`{kind='cu'}`). `targetPlan` and
`wm:pokeEdgeGain` share this one decision so the two code paths stay
consistent.

## targetPlan shape — outWires, intraConns, masterFeed semantics

`outWires` carries one entry per inter-class wire (no collapse).
`intraConns` carries one entry per intra-host connection, including
source-from and master-to anchors at track-IO pair 1, and synth-CU
splices. `masterFeed` names the (post-fold) audio producer whose
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

## CU bridge invariant — edge ops and folding

An edge's gain/channelMap op rides the edge as metadata. The CU
bridge synthesised for an unfolded gain carries `originEdgeIdx` so the
applier can stamp `opFxGuid` back via `wm:mutate` after
`TrackFX_AddByName` succeeds. `channelMap` never folds onto a send
because sends carry no remap capability. `ctx:gainSinks` is the
authoritative fold decision shared by `targetPlan` and
`wm:pokeEdgeGain`.
