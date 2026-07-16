# rebuild as a pipeline — the target dataflow

> Companion to `design/interval-dirt.md`: that plan narrows *what* a
> rebuild re-derives; this one fixes the *shape* the derivation
> converges to as those phases land. It is the review standard for the
> restructure half of phases 3–5, and § Owners assigns every
> cross-cutting shape a phase — an incremental restructure stays viable
> only while no shape is unowned, because unowned shapes are how the
> current string accreted.

## The complaint

`rebuildPipeline` (`trackerManager.lua:3093`) is nine named, ordered
stages: the control flow is already a pipeline. The dataflow is not.
Every stage reads and writes shared mutable state, so phase boundaries
exist in time but not in data, and nothing enforces what a stage may
depend on:

- The `fx` blackboard — five parallel per-channel tables written by
  `internals`/`ccs`/`regionPark`/`fx` and consumed by
  `tails`/`pbs`/`pcs`; `regionPark` deletes seats out of `ccExisting`
  mid-flight, adjacent to a documented silent-drift hazard
  (`docs/trackerManager.md` § Region-replace parking).
- The `deferred` batch — created at the pipeline head, filled by
  `regionPark` and `fx`, committed inside `rebuildTails`, then patched
  after the fact: the restored-note token re-wiring exists because the
  commit point sits two stages from its writers.
- `computeFxWindows` runs twice — a fixpoint hiding inside a linear
  stage list (§ The placement fixpoint).
- Columns are working state and view surface at once, and switch frame
  in place: `projectLogical` overwrites `evt.ppq` with `ppqL`, so raw
  ceases to exist mid-pipeline and every stage carries an implicit,
  uncheckable tag saying which frame it may assume.
- The pipeline's own `ds:assign`s fire re-entrant `dataChanged` that
  subscribers must drop while `rebuilding` — converged output on the
  same channel as user edits.

## The model: a round-trip through intent space

REAPER plays the take, so **the take is the realisation**: clipped
note-offs, fake pbs, cc fill seats, derived notes all live in raw
MIDI, with authored intent embedded via stamps. The vocabulary already
exists per domain — detune is intent, pb is realisation
(`docs/tuning.md`); host+pattern is intent, fxNotes are realisation
(note-macros) — rebuild is the one place the domains interleave, and
its true shape is a round-trip:

```
sources = read()              -- ONE snapshot: mm events, ds intent keys,
                              --   recognition baseline, swing (§ ds keys)
intent  = recover(sources)    -- INVERT realisation: partition stamped
                              --   internals vs diverged externals, lane
                              --   placement, seat recognition, parked-spec
                              --   partition, PA attachment
intent  = settle(intent)      -- the placement fixpoint: windows ⇄ park
target  = derive(intent)      -- FORWARD: fx expansion, tail walk,
                              --   absorber pbs, PC streams (§ DAG)
          reconcile(…)        -- not a terminal phase: ordered commit
                              --   nodes inside derive (§ Commits)
columns = project(intent ∪ target)  -- logical-frame view surface
```

Today each domain runs its own recover→derive→reconcile loop inline
against the shared state above, with inter-domain ordering held by
comments. The restructure makes each boundary a value: a stage is a
function from declared inputs to a returned output, and what crosses a
boundary is visible in the signature.

## The frame law

**No event list is ever part-raw, part-realised.** Within one list,
every event is at the same stage of the pipeline — one frame, one
derivation state, declared for the whole list. A half-projected list
is unrepresentable between stages, not merely avoided.

Consequences:

- **Columns are logical-only.** Whatever lands in `channels[].columns`
  is already projected. Interval materialisation (phase 3) clones and
  projects in a stage-local scratch list and splices only logical
  events; `delayC`/`endppqC` are computed at the projection point,
  where raw is still in hand.
- **Raw lives in stage-local working sets.** Stages that consume raw
  order (the tail walk's groups, seat reconciliation) read raw-frame
  working structures, never columns. `interval-dirt.md` open question
  5's raw-order anchor query and this law share one answer: the
  raw-order source that serves interval closure serves the walk.
- **Carry-forward is preserved by construction.** Today a carried
  column is "already logical" by a per-channel argument
  (`docs/trackerManager.md` § Derivation dirt); under the law it is
  logical by invariant. The in-place frame switch — currently the
  retention mechanism — is superseded rather than deleted: retention
  survives because columns never leave the logical frame at all.

## ds keys, sorted

The round-trip is helical, not circular: some ds state is intent, some
is realisation history persisted for the next pass's recovery. Today
they are one bag; the model sorts them:

| key | role |
|---|---|
| `fxRegions`, `fxPatterns`, `swing` | authored intent |
| `extraColumns` | view intent — grow-only, merge-safe |
| `fxParked`, `fxParkedCC` | **displaced intent** — authored events the pipeline moved off-take; pipeline-written but carrying intent, partitioned each pass, never re-derived |
| `prevWindows` | **recognition baseline** — this pass's realised window set, persisted for the next pass's seat and park recognition |

Reads hoist into the single `sources` snapshot at the head
(§ The pre-phase). Writes are commit nodes with declared inputs; the
baseline write is last by definition — it is the pass's own output.

## The placement fixpoint

Parking is genuine realisation→intent feedback inside one pass, and
the model names it rather than filing it under recovery: windows are
derived geometry; they decide park membership; `rebuildRegionPark`
rewrites the intent store (mm deletes plus `fxParked`); windows
recompute because unparking changed what the first scan read. Today
this is a hardcoded two-iteration fixpoint with no convergence
argument — unverified whether the second scan can newly *cover* an
event that should park this pass; if it can, convergence defers
silently to the next rebuild.

Phase 3 gates both scans and owes the argument. Candidate resolution,
parallel to the cascade exemption (`interval-dirt.md` § The cascade
commutes): if scan 2 discovers new coverage, **seed it for the next
maintenance pass** instead of iterating — escapes become explicit
seeds under a scheduling guarantee, not silence.

## The derive DAG

"Derive" is not a flat phase; it is a chain whose load-bearing edges
each have a named reason. Writing them down lets a restructurer tell
necessary order from incidental order:

| edge | reason |
|---|---|
| internals → externals | externals pack lanes against the placed internals |
| externals → windows | externals bound fx windows |
| externals → PA dispatch | foreign-MIDI PAs must find their host |
| settle → fx expansion | producers read final on-take columns (a restored host falls back to on-take augment) |
| fx expansion → tail walk | predicted fxNotes walk with real notes |
| tail walk → pbs | absorbers reseat against the **post-walk** lane-1 layout |
| externals → pcs | a foreign note inherits its sample from the prevailing PC |
| everything → project | columns settle before the view frame is cut |

An edge absent from this table is incidental: a phase touching those
stages may reorder freely, and must add a row if it creates a new
dependency.

## Stage returns: shaped by producer

Blackboard → returns has a degenerate outcome: the shared table
reshuffled into long positional parameter lists — signatures grow, no
structure gained (`rebuildPbs(noteLive, pbChains, pbBase)` is the
style, already in the tree). The measured dataflow says this is
avoidable: the `fx` blackboard is five point-to-point channels in one
bag — every field has exactly one producer, and no stage consumes
more than two:

| field | producer | consumers |
|---|---|---|
| `noteExisting` | internals | fx expansion |
| `ccExisting` | ccs | regionPark (mutates), fx expansion |
| `noteLive` | fx expansion | tails, pbs, pcs |
| `pbChains` | fx expansion | pbs |
| `pbBase` | fx expansion | pbs |

The rules that keep returns from degenerating:

- **A stage returns one record of what it produced**; consumers take
  the records they read. fx expansion returns one record carrying
  `noteLive` + `pbChains` + `pbBase`, and `rebuildPbs` takes that one
  record, not three positional fields.
- **No `ctx`.** One aggregate threaded through every stage is the
  blackboard renamed. A stage's signature carries only what it reads.
- **Parameter count = in-degree in the derive DAG.** Signature width
  is a measurement, not noise: a stage ballooning past its DAG row
  means the edge table above is missing rows — add them; don't hide
  edges in a bag.

## Commits: ordered and declared

One terminal commit is not achievable and is not the target. Three
commit groups are genuinely ordered — the tail walk's atomic commit
(host clips + fxNote del/add + park restores in one `mm:modify`: one
`MIDI_Sort`, canonical delete-first), then absorber reseats, then the
PC stream — and tokens are minted at commit, so a later consumer of a
fresh token must read back (today: the restored-note re-wiring). The
enforceable demand is weaker than one commit and stronger than the
status quo:

- **Every commit is a node in the DAG with declared inputs** — no
  batch object threaded through stages and committed far from its
  writers.
- **Read-backs are declared outputs of a commit node**, not post-hoc
  patches.
- **All commits land inside the `rebuilding` window.** A write landing
  after the guard drops turns converged output into dirt and
  self-triggers a rebuild; the loop terminates only because a
  converged pass writes nothing — zero-write convergence, currently
  pinned by no spec (§ The pre-phase).
- ds commits: `extraColumns` (grow), `fxParked`/`fxParkedCC`
  (partition output), `prevWindows` (baseline, last).

## What deliberately stays

- **Reconcile-against-prior.** Content-keyed diffing (`reconcileFx`,
  absorber reconciliation, park partition) is the churn-invisible
  safety net; `interval-dirt.md` § Framing already declined trusting
  direct patches.
- **Frame retention.** Clean channels carry whole projected frames;
  the frame law strengthens retention rather than trading it away.
- **The `rebuilding` reentrancy guard** — though its burden shrinks as
  writes become declared commit nodes.

## Owners

Every cross-cutting shape, assigned. A shape with no owner would be
restructured by nobody.

| shape | owner |
|---|---|
| `fx` blackboard → explicit stage returns | pre-phase |
| scattered ds reads → one `sources` snapshot | pre-phase |
| zero-write convergence spec | pre-phase |
| mid-pipeline ds write timing: audit non-tm subscribers | pre-phase |
| intent/baseline key split | pre-phase (doc + read sites); phase 3 owns the `prevWindows` carry |
| frame law: project-before-splice; raw working sets | phase 3 (columns/projection); phase 4 (walk's raw-order source) |
| placement fixpoint: gate both scans + convergence argument | phase 3 |
| `deferred` threading + token read-back → declared commit node | phase 4 |
| derive-DAG edges kept named as stages are touched | every phase, reviewed against this doc |

Discipline (recorded in `interval-dirt.md` § Implementation plan): a
phase that restructures a stage lands the restructure as its own green
commit *before* its gating commit, so a regression bisects to a half.

## The pre-phase

Mechanical only — shape changes with no behaviour, ordering, or commit
change, pinned by the existing suite and the phase-0 perf baselines:

1. **Sources snapshot.** Hoist the pipeline's ds reads into one read
   at the head; stages take what they need as parameters.
2. **Blackboard → returns.** Replace `fx` with explicit per-stage
   inputs and outputs, shaped per § Stage returns — producer-owned
   records, no flat parameter lists, no `ctx` bag. Least mechanical
   corner: `regionPark`'s `ccExisting` mutation becomes a declared
   input→output — which is the point; the drift hazard gets a
   signature.
3. **Zero-write convergence spec.** Pin "a converged pass makes zero
   mm *and ds* writes" by write-counting on both fixtures (the
   `deepEq` guards at the `fxParked`/`prevWindows` assign sites are
   the existing mechanism). Distinct from the gate-parity pin: that
   says a *skipped stage* writes nothing; this says a *converged full
   pass* writes nothing — the property that terminates the
   self-trigger loop.
4. **ds-subscriber audit.** Establish whether any non-tm subscriber
   depends on the current mid-pipeline timing of
   `extraColumns`/`fxParked` writes, before any commit ever moves.

   *Done — clear to move.* Production `dataChanged` subscribers are
   exactly three: `trackerManager` (self-suppressed, `if rebuilding
   then return`), `groupManager` (reacts only to `groups` +
   `invalidate`), `trackerView` (reacts only to
   `mutedChannels`/`soloedChannels`). Neither non-tm subscriber names
   any pipeline-written key, so the `dataChanged` each mid-pipeline
   `ds:assign` fires reaches no external reactive code regardless of
   where in the pipeline the write lands. Every pipeline ds write also
   happens under `rebuilding = true` (set before `mm:batch`, cleared
   after), so even the tm echo is dropped. The one cross-layer reader
   is `trackerView`'s park-cell tagging (`trackerView.lua:3947` reads
   `prevWindows`), but it runs from the `rebuild`-signal handler —
   after the pipeline commits `prevWindows` and fires `rebuild` — so it
   depends only on **write-before-`fire('rebuild')`**, the ordering
   § Commits already guarantees ("baseline, last"), never on
   mid-pipeline position. The commit relocations in phases 3–4 are
   safe against subscribers as long as they hold that one invariant:
   all ds commits land before `fire('rebuild')`, inside the
   `rebuilding` window.
