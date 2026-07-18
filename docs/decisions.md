# Decision log

One dated entry per non-trivial design decision: what was chosen, over
what, and why — one or two lines. Newest first. The commit skill
prompts for an entry at commit time.

- **2026-07-19** — Continuous cc gate keeps by target scope, not kept records. The design's
  `{ window, kept = true }` cc records proved geometrically inert once emission clips to the emit
  scope (a kept window can never intersect it), so the kept side is a per-target merged window set
  computed at classification; existing seats inside it but outside the emit scope re-feed the
  reconcile verbatim. Kept pbChains records (commit 4) stand — pb seats are markerless downstream.

- **2026-07-19** — The gate verdict now reaches the tail walk. A gate-kept fx spec (verbatim from
  last pass, identity-kept in mm) no longer seeds tail-walk disturbance: it rides `extras` as a bound
  anchor only, and just fresh (re-run producer) derived notes count toward `FRONTIER_SEED_CAP`. The
  2026-07-18 gate killed mm re-writes but left the walk re-clipping every kept note, so on glasswork
  chan 1 (24 parked `retrig` hosts, 256 derived notes) a one-note edit fell to the linear walk and
  re-bound all 256. Now it stays on the frontier (tails 13.0->0.4ms); the predecessor-probe and
  settle-cascade still re-clip kept notes adjacent to a real edit. See docs/trackerManager.md §
  Rebuild: tail walk.
- **2026-07-18** — fx producer gate (interval-dirt phase 5, commit 1): under seed-list dirt a
  pure-note producer (`generators.hasContinuous` false) whose window no seed touches is skipped and
  its derived notes identity-kept via `noteExisting` — `reconcileFx` self-matches them by `fxKey`.
  Only pure-note producers gate; continuous chains still run wholesale (the deferred half). Measured
  on glasswork: the win is ~0.4ms (`fx` 1.6→1.2 skipping all 24 chan-1 parked producers) — pure-note
  producers are cheap, so the macro cost is the continuous side, not note expansion. See
  design/interval-dirt.md § Phase 5.
- **2026-07-18** — Tail rebuild routes by seed count: sparse dirt (≤ 16 seeds + derived events) takes
  the frontier probe walk, dense and wholesale keep the linear walk; the shadow-compare retires. The
  flip unmasked a divergence the shadow had hidden: its `resolve` (live→scratch) returned nil for any
  record not in the note scratch, silently filtering the pb/cc seeds `tm:byUuid` resolves. The live
  frontier had no such filter and bucketed on a nil pitch. Fixed by scoping resolution to a note on the
  channel, matching the linear walk's note working set. Lesson: a shadow harness's own plumbing can mask
  a bug the real path will hit. See docs/trackerManager.md § Rebuild: tail walk.
- **2026-07-18** — `rawThenLogical` strengthened from `(ppq, ppqL)` to a total order: authored-
  before-generated, then lane, then pitch break exact-seat ties. The frontier probe walk reconstructs
  settlement order from the comparator, but a same-tick same-pitch pile had no defined order under the
  two-key sort — Lua's unstable sort left it arbitrary, so the shadow disagreed with linear per-record.
  The tiebreak is meaningful (authored wins) and only pins down what was already undefined. A second
  discipline followed: settlement gathers each pitch's cascade chain against the pristine index, then
  settles by position — probing an index being mutated mid-pass unsorts it and the search cycles. See
  design/interval-dirt.md § Phase 4.75.
- **2026-07-18** — Dirt model inverted: seeds (event-anchored, verb-born, birth-snapshot-carrying)
  are the stored truth; intervals demoted to a per-consumer derived view, `intervals.lua` retiring
  on phase 4.75's commit schedule. Chosen because every consumer after the seek-walk design wants
  events, not geometry — the seek's delay slack and the lane-shield scan were both prices of
  intervals forgetting their birth events. See design/interval-dirt.md § The model, inverted.
- **2026-07-18** — The tail walk re-trues `rawIndex` itself (`resortRawNotes`, under the existing
  rare `anyNudge` branch) after nudging shared entries' ppq in place. Chosen over teaching
  `idxReconcile` to detect the move: its unchanged-ppq fast path compares against an entry the walk
  already mutated, so reconcile-side detection would need a separate sorted-slot key — the stainer
  re-sorting is smaller. See design/interval-dirt.md § Phase 4.5 landed note.
- **2026-07-18** — um's `rawIndex` widened to every note (all lanes, raw-then-logical order) with
  readers filtering at use, and column cells now reach raw consumers via a `colEvt` seat stamp on
  the index entry — stamped where columns seat, surviving reconciliation — rather than a per-pass
  column scan. Chosen over caching the scratch: the index is the already-maintained cache. See
  design/interval-dirt.md § Phase 4.5.
- **2026-07-17** — `util.picker` (compile a key list once) added beside `util.pick` rather than
  memoizing the parse inside `pick`. `pick` re-parses its key string per call: 9.7ms of pure gmatch
  in `buildRawScratch` alone, more than the whole phase-4 tail-walk commit returned. *Chosen over*
  a memo table in `pick` — which would be invisible to callers but would still make `util.lua:3`
  ("no module-level mutable state") a judgement call rather than a flat rule — and over converting
  all 15 `pick` sites to key tables, which would cost twelve cold sites their readable
  space-separated string to fix the two hot ones. The closure owns the list, so util stays stateless.

- **2026-07-17** — The tail walk's narrowing is worth ~0.8ms of 11.7 on the dense take, and it lands
  anyway. *Chosen over* dropping it and keeping only the group deletion (which is where the other
  ~2.9ms is): the seeded sweep is what makes the emitted seat closure *correct* for phase 6, and it
  is ~10 lines. The measurement's real finding is that `tails` cannot narrow below its input —
  `buildRawScratch` clones every non-derived note of every dirty channel with no dirt test, so the
  array build, the sort and the two O(N) passes are all forced from upstream. The walk's body
  narrows to the dirt; the walk's cost does not.

- **2026-07-17** — `voicing` keeps the separation *verdict* and gives up the traversal
  (`nudgeOnsets` → `separateOnset`). *Chosen over* passing a seed predicate into `nudgeOnsets`:
  which predecessor counts as settled and how far a cascade runs are facts about interval dirt,
  which only the caller has — and tm's walk and mm's backstop now genuinely want different
  traversals over the same verdict.

- **2026-07-17** — W542 ("empty if branch") ignored repo-wide. All four hits are an enumerated case
  whose action is deliberately nothing — `divert` in DAG's connection triage, the rewire-to-same-port
  no-op that would otherwise burn an undo entry — and each carries a comment saying why. *Chosen over*
  rewriting them as negated guards: the empty branch is how this code says "this case is handled, by
  doing nothing", and a guard hides the case rather than stating it.

- **2026-07-17** — Unused *arguments* stay; unused *bindings* go. `unused_args = false` (same day)
  spared prod's dispatch-table and stage signatures, where the callee cannot choose its parameter
  list — but a caller writing `local h, wm = mkWm(harness)` picks what to bind, so there is no
  protocol to protect and `_` is the honest name. *Chosen over* extending the args exemption to
  locals: the check earns its keep in specs, where an unused binding often means a forgotten
  assertion — it is what exposed `zz_probe2_spec`, which asserts nothing at all.

- **2026-07-17** — W512 ("loop is executed at most once") ignored repo-wide. Its only three hits were
  the deliberate take-any-element-of-an-iterator idiom, which `next()` cannot express against a
  stateful iterator. *Chosen over* a tests-only scope (the idiom is equally valid in prod, so the
  split had no principle behind it) and over a `util.first` helper, which would have been production
  shape authored for a spec's convenience.

- **2026-07-17** — The flush's descending `flushAssigns` sort stays, demoted from load-bearing to
  defensive. `assignNote`'s eviction guard (same day) made *either* commit order leave `collisionIdx`
  correct, so the sort no longer rescues a peer's slot from an occupier; what it still buys is one
  fewer transient same-seat collision, and every pending key costs the backstop a full note-array
  walk at the unwind — measured at ~65µs on glasswork against a ~17.7ms flush. *Chosen over*
  removing it: one comparison that spares a scan is worth keeping, and the comment was what had gone
  wrong, not the code. The backstop's own `steady state finds none` contract was left alone because
  a probe showed it already true — on the flush path mm's commit drives reload→rebuild from inside
  `flush()`, so the tail walk separates first and the backstop finds nothing; disabling either layer
  still separates, so the two are redundant rather than jointly required. The reported premise that
  the walk never runs on that path was wrong, and `docs/trackerManager.md`'s "a rebuild always
  follows a flush" was right.

- **2026-07-17** — Not every luacheck shadow is a defect. A *protective* shadow stays where a pure
  function must not reach its module's upvalues (trackerView's `projectionEpoch` shadows
  `length`/`timeSigs` by design), as does a local mirroring the field it fills (editCursor's `partAt`
  → `col.partAt`). The rest were renamed at the root, not the site: `newScope`'s arg became
  `scopeName` because the collision was scope-name vs command-name, and editorPage's module-level
  `ctx` was deleted — it was the only page of ten declaring one, so the outlier moved rather than the
  shared `renderBody(ctx, w, h, dispatch)` interface. *Chosen over* renaming at each flagged site,
  which treats the symptom and leaves the ambiguous name in place.

- **2026-07-17** — luacheck's `.luacheckrc` carries the policy rather than the code bending to the
  linter: `unused_args = false`, because uniform call-site signatures are the idiom here
  (generators.lua:6 declares the stage protocol; viewContext.lua:49 documents `chan` as deliberately
  unused; trackerView.lua:2638 already suppressed the same false positive by hand for
  lua-language-server), and `max_code_line_length = 150` as a runaway guard, not a style rule, so
  deliberately aligned tables (timing.lua:133) survive. Comment length stays with
  comment_hygiene.py, which knows `--shape:` is cap-exempt. *Chosen over* renaming 35 protocol args
  to `_`-prefix and reflowing 44 lines — both damage readable code to satisfy checks that do not fit
  the idiom — and over dropping length checking entirely, which leaves nothing to stop a new
  400-char line.

- **2026-07-17** — The field-access index lives in the `.map` itself (`# Fields`, `@field r|w`, rows
  chunked at 12 sites) rather than a sidecar file: one derived artifact, greppable alongside the
  annotations. Table-constructor keys and `function recv.name(` declarations count as writes so
  producer sites are covered. *Chosen over* a sidecar (splits the artifact, needs a second parser
  path) and dot-writes-only (misses exactly the constructor producer sites the feedback log got
  burned on).

- **2026-07-17** — `map_query`/`reaper_doc_lookup` queries are regex (query substring-matched,
  module anchored), not glob: the only consumer is an LLM whose muscle memory is regex, and glob's
  anchored fullmatch was why every logged query wore wrapping stars. Invalid regex errors loudly
  with a translation hint; a quantified literal (`rebuild*`) gets an advisory note. *Chosen over*
  glob + `|` alternation, which patches glob toward regex one metacharacter at a time.

- **2026-07-17** — `collisionIdx` holds **notes only**, and `assignNote` evicts only the slot it owns.
  The table exists to detect MIDI's one-voice-per-`(chan, pitch)` rule, which is a note property, so its
  cc/pa/pb/at/pc entries had a writer on every path and a reader on none — dead from the moment
  `eventsByUuid` took over addressing and `tokenIdx` stopped doubling as the address book. Dropping them
  collapses `contentKey`'s five branches to `seatKey`'s one and takes a concat plus a table store per cc
  out of rebuild's bulk loop, the one path that runs every event every flush. *Chosen over* leaving them
  as harmless: an index written and never read reads as load-bearing to everyone downstream. The
  eviction guard mirrors `mm:delete`'s and is *reached* — the tail walk's own nudge commit trips it
  (`vm_delay_entry_spec`, found by counting hits across the suite), where the unguarded evict wiped the
  survivor's slot and only `pendingCollisions`' coarse `(chan, pitch)` key plus `resolveCollisions`'
  whole-group rescan covered for it. Not a bug — but a live dependency on another module's key width,
  and now a local one.

- **2026-07-17** — `resizeNote` both *decides* and *performs* PA translation in the logical frame; the
  two raw-frame computations that outlived the ownership move go. Its gate asked whether the raw delta
  held at both endpoints — true under swing only when the note's logical length is an exact multiple of
  the swing period, since only then do both endpoints keep their phase. At any other length a whole-note
  move read as a resize and culled the PAs it should have carried (pinned red first). *Chosen over* a raw
  gate with an `OPEN` special case: comparing logical **lengths** lets `math.huge` handle itself, as huge
  minus either seat is huge. The carry moved for a sharper reason — it now realises the moved seat via
  `fromLogical` instead of adding the host's raw delta, because on a settled channel `rebuildCCs` reads a
  raw/seat disagreement as an external edit and restamps `ppqL` from the raw, so the fabricated
  realisation overwrote the intent the carry existed to preserve.

- **2026-07-17** — tm separates same-pitch collisions at exactly one site, the tail walk; the reseat's
  and flush scan's nudges go. *Chosen over* keeping them as cheap insurance: the walk and mm's backstop
  each separate independently — proven by disabling each in turn, where only killing *both* lands two
  voices on one raw — so the nudges were the third and fourth layers on one collision. The flush scan's
  *kills* stay: `nudgeOnsets` separates but never kills, so a duplicate reaching the walk is one nothing
  below will collapse. Corollary for the pins: with two sufficient layers no single-layer break can go
  red, so the specs assert the surviving voice and name no layer at all.

- **2026-07-17** — um owns a PA by its *logical* seat, not the host's raw window. A PA carries its own
  `ppqL` and the CC walk reswings it from that seat, so it was never slaved to its host's realisation
  — but `forEachAttachedPA` tested `cc.ppq` against `[host.ppq, host.endppq)`, so any realisation-only
  shift of the host detached it: a forward delay pushed a note's raw onset past a PA it still owned,
  and um then declined to move or cull it, orphaning it in mm (pinned red first). *Chosen over*
  teaching each nudge site to carry its PAs: attachment is an intent relation, so the frame was the
  defect and the sites were symptoms — fixing it closed the tail walk's nudge and the reseat nudge at
  once, both of which write raw `ppq` only and so now cannot detach anything. `resizeNote` follows the
  seat into the logical frame, which *removes* its `cullEnd` param: that existed only to smuggle the
  logical `OPEN` sentinel into a raw test, and `OPEN` is `math.huge`, so an open tail needs no case.

- **2026-07-17** — um records carry `realised`; the `token` vocabulary is retired everywhere. Pivoting
  mm to uuid made most `.token` reads redundant — a clone already carried `uuid` — but not all: three
  sites read `token`'s *presence* as "this event is in mm, write through to it", and `.uuid` cannot
  say that (a restored parked note keeps its uuid the whole time it is off-take, and `addParked`
  mints `fxp-N` uuids for specs mm has never seen). *Chosen over* keeping `.token` as the flag under
  a name mm no longer uses: the value was always the uuid, so only presence carried information, and
  tm already calls mm-committed events on-take and parked ones off-take. `realised` names that axis
  and `REALISATION` already classified `token` as a realisation field, so `parkSpec` strips it for
  free. mm's `tokenOf`/`byToken` are gone, tm's `byToken`/`byUuid` are one table, `origTok` dissolved
  into the uuid its clone already held.

- **2026-07-17** — mm addresses by uuid; the content key stays private and detects collisions only.
  Tokens did two jobs: an external handle, and (as `tokenIdx`) the same-pitch detector. Only the
  first is replaceable — key that index by uuid and it can never collide, so `noteCollision` would go
  silent. So `tokenOf`/`tokenIdx` became `contentKey`/`collisionIdx`, private; `mm:tokenOf` returns
  `evt.uuid` and every verb resolves through `eventsByUuid`. *Chosen over* adding uuid verbs beside
  the token ones and migrating callers: tokens were already opaque, so pivoting what they carry moved
  every caller at once. Identity now survives an identity-field move, which retires three workarounds
  for the ambiguity of a shared content key — the cc-restore `dropFillSeat` dance, `mmBatch`'s re-key,
  and pb `origTok` capture. It also costs one invariant that came free: a ppq move no longer re-keys,
  so `idxReconcile` must check `ppq` explicitly to keep `chans` ppq-sorted.

- **2026-07-17** — identity is not persistence: every event mm mints now carries a uuid, and a cc with
  no metadata is `plain` — its uuid is in-memory only, re-minted each load, no `}RDM` sidecar, no
  eventMeta bucket. Previously the two were one decision (a cc got a uuid exactly when it got a
  sidecar), which left markerless pb seats with no handle at all and forced content-keyed tokens to
  serve as addressing. *Rejected:* stamping uuids universally with sidecars to match — route-by-window
  exists precisely so a resynthesised absorber seat stays plain native MIDI, and a sidecar per seat on
  a dense pb stream is the cost that design avoids. The invariant round-trips by construction rather
  than bookkeeping: load derives `plain` from what bound no sidecar, and `plain` is structural, so it
  can never ride a metadata blob and contradict the take. First step of retiring tokens from
  addressing (uuid verbs, then callers, then tokens go private to mm's collision detector).

- **2026-07-17** — materialisation takes raw seeds, no closure: `noteClosure` and `intervals.close`
  are deleted, and `exciseNotes` excises the merged seed points directly. The drafted rule —
  materialise the union of the consuming stages' closures — rested on those stages reading the fresh
  clones, and they don't: every raw consumer reads `buildRawScratch`, built whole-channel from mm,
  which resolves carried and freshly-cloned events alike by uuid and writes back through a `colEvt`
  backref, so a carried event whose mm note is unchanged is already correct. The closure was
  materialising ~90% of the channel and changing no output (suite identical at 2043 either side).
  `close` went rather than staying dead for phase 4: its contract (events logical in `.ppq`) is the
  opposite of the walk's scratch frame. Closure is the tail walk's, against its own raw-order scratch.
  (The entry originally gave a second reason — that `opts.key` served groupings the same-pitch commute
  would remove. There is no commute; the groupings stay. The frame mismatch carries the decision alone.)

- **2026-07-17** — same-pitch stays in tm entire, applied where tm projects intent into raw, beside
  swing and delay (design only; phase 4 implements as clip → uuid+consolidate → interval walk).
  Supersedes the same-day entry below, which sent clip *and* clamp to mm on the argument that mm owns
  the raw frame. Three facts kill it. (1) mm's backstop detects by exact token match
  (`(evType, chan, ppq, pitch)`): it sees colliding onsets, and is blind to tail overlap. (2) A clip in
  mm's stored `endppq` churns forever against `rebuildTails`, which re-derives the unclipped lane bound
  and writes it back every rebuild — `tm_zero_write_spec` red on both fixtures. (3) Decisive: **the
  backstop kills and the clamp doesn't**. `redundant` (`voicing.lua:20`) is true unconditionally when
  one note is derived and the other isn't, so `resolveGroup` deletes an fxNote that collides with an
  authored note, where `nudgeOnsets` separates it — and the walk is the only site where the two meet
  before commit. So the walk computes two bounds: lane-only drives `endppqC` and the screen,
  lane ∧ same-pitch drives mm. The view rule stands (clip what the view can't draw, don't clip what it
  can): same-pitch overlap draws as authored, unrealisable intent shown. `delayC`'s re-stamp stays — the
  walk still nudges mid-pass, which is what forces it. The flush pre-clip's tail loop goes as a vestige
  (its scan earns its keep on `resolveGroup`'s kill verdicts, not truncation). Separation still lands
  exactly once, but in tm: `tokenOf` aliases a colliding pair onto one name across the pipeline's nine
  mm commits, which is the whole reason three sites separate rather than one; uuid addressing dissolves
  that and the walk absorbs the other two. I8 survives intact, phase 4 included, because tails *produces*
  its closed interval rather than consuming one: closing an interval means finding each seed's same-lane
  and same-pitch neighbours, which is the same lookup the tail bound already needs, so the walk sweeps
  out from its seeds and emits the anchors for seats and PCs (which run after it, `trackerManager.lua:3221`
  vs `:3229`/`:3230`). A fenced walk would have needed a net for cascades leaking past the fence, and the
  backstop cannot be one — same fact (3): it kills the escaping fxNote rather than nudging it, and reports
  `kind = 'killed'` events naming notes that no longer exist. Unfenced, nothing leaks.

- **2026-07-17** — *superseded the same day by the entry above; kept for the argument it lost.*
  same-pitch commutes to the wire entire, clamp *and* clip. Ownership, not taste: same-pitch exclusion
  constrains the raw frame, mm owns that frame, and both layers already drive one pure module
  (`voicing.nudgeOnsets` in tm's walk, `voicing.resolveGroup` in mm's backstop, whose contract reads
  "steady state finds none"). Taking only the clip was rejected: `nudgeOnsets` groups internally, so the
  clamp would survive and the closure union with it. The lesson worth keeping: the layering argument was
  never checked against mm's code, and the two facts that killed it were both one grep away.

- **2026-07-16** — interval dirt materialises note columns and nothing else: every other producer (ccs,
  park, pb) still gets the fresh channel a dirty chan has always been handed. Carrying the whole channel
  was tried first and broke 18 specs — those stages clone from mm and append, so a carried `.parked` /
  `columns.ccs` doubles up. Confining the carry keeps the biggest number (`internals`, 18.5ms of ~34) and
  leaves the rest to phase 3's remainder. Two designs for foreign/diverged notes inside an interval were
  worked up and both dropped as dead code: a widen-to-wholesale fallback, and seeding the externals' own
  positions. Neither state can arise — every external mutation routes through `mm:load`'s full re-read,
  and `tm:rebuild`'s `didReload → dirtyChan()` widens *after* `absorbSeeds` narrows, so a diverged note
  can never sit in an interval-dirty channel. That ordering is load-bearing and unpinned: pinning it needs
  harness surface we didn't want to author, and if it inverts, `intervals.intersects` takes a nil ppqL and
  errors loudly rather than deriving silently wrong output. Interval bounds also lost their `L` (`loPpqL`
  → `loPpq`): single-frame algebra, one construction site (`seedEvent`'s `evt.ppqL or evt.ppq`), and once
  `close` moved to `e.ppq` the suffix read as a frame mismatch that wasn't.

- **2026-07-16** — foreign MIDI keeps its logical anchor: the CC walk stamps every sidecar-less
  non-derived cc/pb/pa/at with `ppqL = toLogical(raw)` on the first rebuild that dirties the channel
  (`rawDivergesFromLogical` reads a missing sidecar as divergence). Reviewed under the theory that
  imported automation should stay sidecar-less to keep dense takes small, and kept: the anchor is what
  lets a later swing edit reseat an imported event (`staleSwing` → `fromLogical(cc.ppqL)`), so without
  it an import would freeze in raw while the rest of the take reswings. Two corrections fall out. The
  entry below overreached — A2 made the `ppqL` read redundant for *notes* (externals stamp those); for
  the cc family it is this stamp that does it, which is why A2b's sweep held. And the cost is real but
  unpaid-for: the stamp mints a uuid per imported event, so a dense automation take grows an eventMeta
  entry per cc on first rebuild. Already pinned, end to end, by `tm_cc_gating_spec`.

- **2026-07-16** — one frame per surface: `ppqL` retires everywhere except mm. Columns, the fx/park
  stash, parked render cells and generator streams all key plain `ppq` (logical), and `projectEvent`
  strips the `ppqL`/`endppqL` sidecar as it seats an event — over A2's duplicate stamp. Two names for
  one number invited frame-mixing, and had: a cc restore seated a *raw* onset on a logical column,
  `realiseParked` clobbered the authored ceiling to carry the render clip (now `endppqC`, leaving
  `endppq` authoritative for the view), and `setLength`/`rescaleLength` still read a `ppqL` A2 had
  made redundant. `parkSpec` inverts accordingly — it strips realisation (`delayC`/`endppqC`) and lets
  `ppq`/`endppq` ride; an mm-raw source overrides `ppq` explicitly. `sortByPPQL` became
  `sortNoteColumn` rather than merging into `sortByPPQ`: only note columns interleave notes and PAs,
  so merging would widen that tie-break onto the mm-side sorts `sortByPPQ` also serves.

- **2026-07-16** — columns project to logical **at build** (note columns right after externals — the
  partition/reseat/lane-packing stages need raw; cc-family as they seat), the tail walk re-stamping
  `delayC`/`endppqC` on movers — over the pipeline-tail `projectLogical` pass. Its hidden second job
  became explicit: cc/at/pc columns sort at build, and `sortByPPQL` gained the deterministic tie-break
  (note before its PAs, then pitch) that replaces the old sort's arbitrary equal-onset order.

- **2026-07-16** — map `@use` edges store the receiver **source-faithfully** (`cm:get`, `util.deepClone`
  — instance name, separator kept), resolving short name → module at **query** time via each map's `self=`
  registry — over resolving at generation time. Generation stays a pure per-file transcription, so a
  post-edit regen never depends on another file (rename a module's `self=` and no chunk map goes stale).
  `map_query usedby` becomes a genuine reverse scan (was the same loop as `uses`): it scans every map,
  matches the target through the registry accepting all four spellings, and `module=` names the *used*
  target, not a file to read — fixing the twice-logged back-to-front.

- **2026-07-16** — rebuild's target dataflow fixed (`design/rebuild-pipeline.md`): round-trip through
  intent space with ordered, declared commits — over a single terminal commit (three commit groups are
  genuinely ordered and tokens mint at commit) and over the status-quo blackboard. Frame law adopted:
  no event list is ever part-raw, part-realised; columns go logical-only, raw confined to stage-local
  working sets. Lands via interval-dirt phases 3–4, mechanical pre-phase 2.5 first.

- **2026-07-15** — interval-dirt phase 2 (seeds born at the verbs): a delete seed carries the deleted
  event's own (dying) uuid, rather than hand-anchoring to the surviving neighbours the design names.
  `intervals.close` already re-anchors a point to its neighbouring onsets at consumption, and `merge`
  reads only ppqL, so the dead uuid is never dereferenced before close replaces it — hand-anchoring
  would duplicate that work and pull in the raw-order index deferred to phase 4. Per-verb seed shapes
  are pinned by zero-behaviour (suite + `tm_gate_parity_spec` green), not a test-only `tm` accessor;
  the pure fold (`intervals.absorbSeeds`) is unit-specced directly.

- **2026-07-15** — the `incremental-rebuild` programme is closed and archived; its one open gap (4,
  the fx dirt signal) is **deferred rather than done**. fx-hosting channels are marked dirty wholesale
  every rebuild, and the obvious fix — hash the generator inputs per host — was rejected: it bolts a
  second dirt axis alongside `dirtyChans`, to be plumbed through every stage that reads it, and the
  successor deletes it again. That successor (`design/interval-dirt.md`, live, unstarted) makes the
  dirt unit a **ppq interval within a channel**, and fx then needs no dirt signal at all: a host
  regenerates exactly when a dirty interval intersects its window, which `computeFxWindows` already
  yields as a per-host logical-ppq extent. The channel model is the degenerate case (interval = whole
  channel), so the migration is stage-by-stage. Convention this sets: `design/` is live work, `design/
  archive/` is finished — so a closed programme moves wholesale, and anything still live in it gets
  spun out rather than buried. Archiving repointed 31 inbound `see design/…` pointers.

- **2026-07-15** — `cm:get` resolves one key by walking the tiers, instead of materialising the merged
  table. Building it cost 164 default copies + 5 tier overlays to answer a question about one key: a
  scalar read was 13µs against the 0.13µs of a single-tier `getAt`, and the cost had already leaked
  into callers as hand-rolled memos (tm's `pbLimCents`, *"too costly to re-fetch per pb"*). The walk
  is exactly equivalent because `util.assign` is a flat overlay and a tier can never hold `util.REMOVE`
  (`assign` deletes before the cache sees it), so "present in the tier" and "wins the merge" coincide.
  Chosen over memoising the merged table, which buys O(1) over O(5) — noise beside the `deepClone`
  both still pay — at the price of a sixth cache and four invalidation points. Scalar reads 13µs →
  0.28µs; table reads keep only their clone (`tempers` 46 → 34µs), which is the ownership invariant.
  Now load-bearing: resolution tests **presence, not truth** (`value ~= nil`), or a tier holding
  `false` loses to a truthy default and every boolean key becomes un-disableable — pinned in
  `config_schema_spec`, which nothing else in the suite was holding down.

- **2026-07-14** — mm writes metadata only where it changed. `load` persisted by rewriting the whole
  pool (`eventMeta:saveAll`) on the strength of an unstated fact: it *reads* metadata and joins it
  onto events, but never edits it — so every surviving uuid's stored bytes were already correct and
  the write was pure churn. It now persists the delta: reassignment clones out, uuids no event claims
  swept (the sweep `saveAll` did implicitly; `mm_cc_dedup_spec` and `mm_cc_reconcile_spec` pin it).
  Chosen over gating `saveAll` behind a did-anything-change flag, which is a smaller diff but helps
  only the native rebind — a foreign take mints every uuid, so the flag is always true on the path
  that hurts. The win compounds: an empty bucket index means the rebuild's flush writes its 40 buckets
  fresh instead of read-modify-writing 33 that load had just created for it (30ms + 26ms). Corollary,
  now load-bearing: **an empty metadata entry is indistinguishable from an absent one**, so neither
  load nor a minted uuid writes `{}`. Same rule downstream — `assignNote`/`assignCC` persist only when
  the assign touches a metadata key, so a velocity edit does no metadata I/O at all (it re-serialised
  a 256-entry bucket + 5 projext-mirror ops). Foreign bind 452ms → 404ms; metadata 27% → 17% of it.

- **2026-07-14** — tm's rebuild pipeline nests in `mm:batch(fn)`, a depth-holder, not an outer
  `mm:modify`. A modify fires `reload` on every unwind whether or not its fn wrote — so a modify
  wrapper announces a mutation that never happened, on every rebuild and every keystroke edit
  (four `mm_signal_flow_spec` cases catch it); gating that fire on `dirty` is out, since
  metadata-only gestures set no `dirty` and still need the reload to drive a rebuild. `batch` takes
  no lock, writes nothing, fires no reload, and propagates errors: mm's signal stream is unchanged,
  and the nine pipeline commits now share one reindex and one `flushTake` on every path, not just
  flush. Foreign bind 539ms → 454ms; take reprojections 3 → 2.

- **2026-07-14** — `chans` belongs to the update manager, so um owns its sort deferral:
  `withDeferredSort(fn)` is the only door. `mmBatch` had been setting `deferredSort` from
  outside the um do-block — a *global*, invisible to the block-local `chansInsert` reads —
  so the deferral never once fired and every insert re-sorted the whole lane (1.7s of a
  foreign Hammerklavier bind). A private local reached from outside its block fails silently,
  as a nil: cross-boundary state needs a function, not a shared name.

- **2026-07-14** — mm's reindex is gated on `needsSort` / `needsCompact`, which describe
  the *arrays* (an add or a ppq move unsorts; a delete holes), not the write — so an assign
  touching neither skips `rebuild` outright. Chosen over the filed hole-vs-order split, which
  buys only the 0.6ms sort or the 0.2ms compact because either fixup moves every `loc` and
  drags the 2.3ms index loop with it. Consequence, and the price: a new mm mutator that
  unsorts or holes an array **must set a flag** — on the skipped path the verbs' incremental
  index maintenance is load-bearing, not laundered by a from-scratch rebuild behind it.

- **2026-07-14** — mm indexes events by channel (`chanIdx[kind][chan].byLoc`),
  and the reindex reconstructs it from scratch every flush. That laundering costs
  +0.9ms against a −2.4ms `reload` win; keying by event instead of `loc` would let
  the reindex skip it, but the collision backstop and load dedup kill events
  *outside* `mm:delete`, so they would have to maintain the index themselves.
  Rejected on gap 2's ruling: no correctness surgery on the backstop, whose failure
  mode is silent take corruption, to buy a millisecond.

- **2026-07-14** — eventMeta stores fields in entry buckets
  (`e.<b> = {[uuid]=fields}`, `b = uuid//256`), not per-uuid slots. Chosen over
  batching the projext-undo mirror's manifest/root writes (the pinned remedy):
  per-uuid slots made pool slot count ≈ event count, and mirror manifests scale
  with slot count — a 384-entry flush cost 585ms on a 14k-event take, now 15ms.
  Kills the keyset cache outright; old projects' metadata is hosed, accepted
  pre-beta.

- **2026-07-14** — `pendingLen`: during `tm:setLength`'s shrink, `tm:length()`
  reports the end tm is *about* to create, not mm's current one. Chosen over
  threading a `takeLen` override through `rebuild` → tails/fx/park (four sites
  that all just call `tm:length()`). The shrink must flush before `mm:setLength`
  moves the EOT (`setEot` cannot sit behind a live note-off), so that flush's
  rebuild would otherwise regrow OPEN tails to the old end and deadlock it.

- **2026-07-13** — Specs get maps. `tests/specs/*_spec.lua` → `map/specs/*.map`
  (`@spec` header, intent/helpers/cases, same `@use` grammar), so `map_query
  usedby` answers "which specs exercise X" instead of a grep-and-read session
  over 51k spec lines. Chosen over a bespoke test index: reusing the map
  grammar means zero new query surface. Receiver→module aliasing rides a
  hardcoded `HARNESS_MEMBERS` mirror of `harness.mk`'s return table — update
  it when mk grows a member.

- **2026-07-13** — Pools never span tracks. REAPER undo on a cross-track MIDI
  pool obeys a one-era law: only the first script run after create/load mints
  working points; later runs silently lose all but their first gesture until
  save+reload (in Continuum, P_EXT traffic turned this into lumped undo).
  Every per-gesture workaround was falsified live, so the rule is structural:
  `dropInstance` unparks the scratch keeper by moving it back to the grid
  (mirroring park-by-move), never cloning. Reported upstream (REAPER 7.77).
  Ledger: docs/arrangeManager.md § Pools never span tracks.

- **2026-07-12** — Every region-mutating ec verb flushes via `groupBridge.commit()`,
  not just the creation verbs. `tm:requestRebuild()`'s deferred flag is inert until a
  flush consumes it, so `dropInstance`/`paintCell`/`resizeBy` (delete/paint/grow-shrink)
  left the rebuild — and tv's `cellKind` region tags — stale until the *next* command
  happened to flush. Commit at the call site (gm only stages; the verb flushes) closes
  it: the resize/delete's own flush now honours the flag this command. Also added the
  missing `tm:requestRebuild()` to `gm:resizeGroup`, which alone among the geometry
  verbs never signalled a rebuild.

- **2026-07-11** — A pb gm member stores INTENT in the group frame under `val`
  (its existing name), and `toGroup` sources it from `evt.cents` — frame-invariant
  intent — never the um entry's `val`, which `makeEntry` builds as `rawToCents(wire)`
  (intent + governing detune, i.e. realisation, stale at any sibling whose detune
  differs). Over renaming the group field to `cents` at every boundary: the intent
  ingress is a single chokepoint (`toGroup`), so one arm there beats N renames, and
  `detune` is already `DERIVED`-denied so the wire re-derives per seat at flush.
  `makeEntry`'s pb pick also now carries `uuid`, without which gm's per-rebuild
  re-anchor (`tm:byUuid`) silently loses the member and no-ops every later edit.

- **2026-07-11** — `tm:requestRebuild()` is a *deferred* force-rebuild: it sets a flag
  the imminent flush consumes past its no-op guard, for a geometry change that stages
  zero mm ops (an empty-group instance verb: nothing to project, so the commit flush
  would otherwise skip the rebuild and leave tv's `cellKind` region tags stale — the
  first edit in the region then misroutes to a plain, non-propagating note). Distinct
  from swing/fxRegions' immediate `tm:rebuild(false)`, which fires from a config/data
  subscriber *outside* any flush; a flag there would have nothing to consume it. Not
  unified — the two serve opposite call contexts (mid-/pre-flush defer vs standalone now).

- **2026-07-11** — FX regions join the rectangle clipboard (copy/paste/delete),
  captured by *onset-in-band* — a region starting inside the rectangle rides whole,
  tail spilling past the band, exactly as a note's tail copies; one starting above and
  merely passing through is skipped. Over overlap-capture (would make fx unlike every
  other column) or clip-to-band (meaningless for a chain, whose identity is its window).
  Paste *stacks* (no destination wipe) since regions overlap by design. Rides the cell
  clip as `clip.fxRegions` via an injected `fx` hook; delete-caret still targets the
  region under the cursor (`cursorRegionBefore`), not the onset rule.

- **2026-07-11** — Chord channel spread rides Alt *per strike* (Shift+Alt+note
  walks to the lowest gesture-free channel; plain Shift+note stacks lanes on home),
  over a mode-at-arm modifier or a config toggle — per-strike subsumes both and
  allows mixed chords. Toggle stays pitch-keyed, so cross-channel unison doubling
  is foreclosed. Chord entry is gated off the pattern surface (gridPane host param
  `chordEntry`; patterns are single-channel bodies).

- **2026-07-11** — Shift-held value entry is a keep-below overwrite cursor over a
  field's places: each digit overwrites only its own place (lower places intact),
  the sub-caret steps right, and the row stays pinned while shift is down.
  Backspace restores the place the last digit overwrote (retype it); shift release
  jumps back to the entry column, then advances. Replaces the old half-a-place
  Shift trick (setDigit's `half` -> `keepBelow`). Hex parts take 0-9a-f, decimal
  0-9 (the a-j additive carry stays a separate non-shift mechanism).

- **2026-07-11** — Chord entry (shift-held): velocity digits live on Shift+Alt, not
  plain Shift, because the upper note row *is* the digit row (`2 3 5 6 7 9 0` are
  black keys/high notes) — plain digits stay strikeable. A struck pitch already at
  the pinned row is adopted into the gesture, never duplicated (one voice per
  (chan, pitch, ppq); the voicing pass would eat a duplicate unpredictably); a
  re-strike toggles off. Accepted: chords can't *start* on 9/0/,/. (Shift-bound
  commands win at dispatch; they decline only once a gesture is live).

- **2026-07-11** — Decimal grid value entry (pb, delay): letters `a`–`j` enter
  digit `0`–`9` at the current place plus an *additive* `+1` carry into the place
  to its left (a tracker range-extender: `a`=10 … `j`=19), clamped to the field cap.
  Chose additive carry over literal-set-to-1 (non-destructive: `350`+tens`b`→`410`,
  not `110`). Dropped the `f`→full-scale special-case; full scale now falls out of a
  carry that overflows the top place and clamps.

- **2026-07-10** — The fx palette tab stands alone: a mouse click pins either tab
  (`tabOverride`, generalising the old params-only override) *without* grabbing
  focus, and `stripPlan` draws a bare add row on a host with no fx. Minting splits
  by entry path — the mouse mints the host lazily on the first `add`, the keyboard
  `editFx` still mints eagerly and pops the picker. Rejected making the keyboard
  path lazy too (kept its eager snapshot/husk-prune session).

- **2026-07-10** — Empty pb cells inherit their entry sign — the displayed
  ghost's, else the previous visible breakpoint's — so a negative run is one
  `-` plus digits and typing edits what you see; explicit zeros don't inherit
  (they display unsigned). The `-` arm is now a flip of the inherited sign, and
  a sub-thousands digit on full scale wraps (clears the thousands) rather than
  clamping to a silent no-op.

- **2026-07-10** — Signed grid entry: `-` sign-flips in place (no advance); on a
  zero cell it arms a *transient* `-0` held in trackerView, not the event —
  pb serialises to a wire where -0 == 0, so a persisted signed zero dies at the
  next flush/rebuild. Key clashes (Shift+8 octave, plain-1 noteOff pattern)
  resolve by commands *declining* in value-part context, not by rebinding.

- **2026-07-10** — Pattern-editor curves default to linear by *seeding* a fresh
  body with two linear zero anchors + having `tv:enterValue` inherit the previous
  breakpoint's shape (like the curve pane's mouse insert). Rejected a
  `newBreakpointShape` config key: seeding needs no per-context default and unifies
  grid-entry with mouse-insert. Main tracker keeps REAPER's step (no linear seed).

- **2026-07-10** — `chrome.screenPainter()` (identity painter over the current
  window's draw list) is the reach for screen-space drawlist work; raw
  `GetWindowDrawList`/`DrawList_Add*` is out — it loses chrome's colour
  discipline (names/tokens, not raw ints). Extracted from three palette sites;
  the fx palette's row-highlight + flow rule adopt it.

- **2026-07-10** — A `pa` parks off-take with its host note (replace-region /
  note-host park), rather than staying take-side and sounding against the fresh
  derived stream (rejected: stale PAs against different derived notes are
  meaningless). It still rides the host's note column for display; the generator
  owns any new realisation PAs.

- **2026-07-10** — FX chain moved from a docked 2D strip to a `parameters|fx`
  palette tab, rotated vertical for 1D nav (Up/Down walk all fields, Left/Right
  edit). fx auto-raises under the caret; Super-R parks a parameters override
  (clears on caret move), Super-X cancels it — symmetric. Chain adopts the param
  tree's row grammar (label left, value column right) for one UI, not two.

- **2026-07-10** — UI vocabulary: tables crossing a pass boundary get
  role-named fields (`xLo/xHi`, `chanLeft`, `pitchWidth`, `viewRows`),
  never bare coordinates; piloted in gridPane, rule in CLAUDE.md.

- **2026-07-10** — Per-file docs stay, as pointer-target overflow for the
  comment caps; rejected wholesale deletion (≈150 `see docs §` pointers
  pin dense WHY that can't compress to site comments).
