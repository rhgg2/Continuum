# fx-metadata spike — where fx-node decoration can live

> Lab record for `design/wiring-implicit-graph.md` § Decoration. Settles the
> "where do fx-node positions persist?" open question empirically. Spike
> script: `tests/spike_fx_metadata.lua` (run as a ReaScript action on a
> scratch project, two phases across a save/reload).

## The question

The implicit-graph design wants REAPER to be the only store and the graph to
be read back from routing. The one thing `read` can never recover is
**view-state** — where an fx-node's dot sits. § Decoration proposed storing
that on the FX itself via a `SetNamedConfigParm` "ext" channel, but flagged it
unverified. The ReaScript API docs list only a *fixed* key set for
`TrackFX_*NamedConfigParm` — no arbitrary-ext equivalent to the track/item
`P_EXT:` mechanism. So the real question was never "does the channel survive?"
but "**which** channel exists at all?"

Three candidates, five survival conditions:

| channel | what it is | C1 | C2 | C3 |
|---|---|---|---|---|
| **C1** | arbitrary FX named-config key (`ext.ctm…`) | — | — | — |
| **C2** | track `P_EXT` keyed by FX GUID | — | — | — |
| **C3** | `renamed_name` field abuse | — | — | — |

| condition | C1 fx-namedcfg | C2 track-P_EXT-by-GUID | C3 renamed_name |
|---|---|---|---|
| R  round-trip | **FAIL** (write rejected) | PASS | PASS |
| C  in chunk (→ survives save) | n/a | PASS | PASS |
| U  undo | n/a | PASS | PASS |
| T  track-duplicate | n/a | key desync¹ | PASS |
| M  FX-move-to-track | n/a | **FAIL** (host-track²) | PASS |
| save / reload | n/a | PASS | PASS |
| GUID key stable across reload | n/a | yes | yes |

¹ data copies with the track but stays keyed by the *original* GUID, while the
duplicate's FX gets a fresh GUID — so a by-current-GUID read misses.
² C2 stored on the *host track* is orphaned when the FX leaves it. Not a
property of GUID identity — see below.

## Findings

**C1 does not exist.** All three key spellings rejected the write. The per-FX
ext channel the design hoped for is not a REAPER feature. That open question is
closed: fx-node positions cannot live *on the FX* via named-config.

**The FX GUID is a durable per-node identity.** The spike showed the GUID
survives save/reload and an FX *move* (`CopyToTrack`, is_move=true preserves
it). The remaining worry was compile: does a *recompile* that re-partitions a
node onto an emergent track preserve the GUID, or delete-and-re-add it (fresh
GUID, lost plugin state)? It preserves it — `wm:diff` already emits
`moveFxAcrossTracks` for any guid the snapshot holds on a different track, and
apply runs it as a state-preserving move. Pinned by
`tests/specs/wm_repartition_move_spec.lua` (the A→B→Master + add-C→B case).

**Undo is a non-issue, but the store's *home* matters.** A standalone track
`P_EXT` write rides native undo (C2.U PASS). Project ext state
(`SetProjExtState`) does **not** — that is the gap the scratch-track mirror
exists to paper over. Node-drags don't need to be undoable, so positions can
live in project ext; the scratch + `pollUndo` apparatus can retire on the
decoration axis.

## Conclusion for § Decoration

Decoration collapses to its simplest possible form:

- **One central store, keyed by FX GUID**, `guid → {pos, name, colour}`,
  alongside source/master node decoration. No per-FX channel (it doesn't
  exist), no `renamed_name` abuse (it works but hijacks the visible name), and
  crucially **no `nodeId → guid` identity ledger** — the GUID *is* the stable
  key, because compile relocates via move, not delete+add. The blob really does
  retire down to "just positions."
- **Home: project ext state** (positions needn't be undoable). The scratch
  track is not required for decoration.

## False alarm worth recording

Mid-spike I read `reconcileFXChain` in isolation and concluded cross-track
relocation does delete+add, silently wiping a user FX's plugin state — flagged
it as a critical bug. It is not: the move op upstream in `wm:diff` prevents that
case, confirmed in REAPER and now pinned by `wm_repartition_move_spec`. The
lesson: the reconcile engine's per-track delete+add is real, but the diff emits
`moveFxAcrossTracks` *before* the per-track passes run, so a relocating resident
FX is moved, never destroyed. Don't diagnose the apply layer without the diff.

## Edits this forces in `wiring-implicit-graph.md`

- § Decoration: drop the "per-FX channel (`SetNamedConfigParm` ext)" sub-case
  for fx-nodes; replace with the single GUID-keyed positions-only store.
- § Open questions: close the "per-FX metadata channel" risk (answer: no such
  channel; not needed — GUID is the key).
- § What retires: the scratch + `pollUndo` apparatus can retire on the
  decoration axis (project-ext store, non-undoable positions) — but note it
  still carries its own undo-coherence job elsewhere.
