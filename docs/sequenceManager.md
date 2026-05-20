# sequenceManager

Project-wide orchestration over the per-take stack. Owns no state of its
own; operates by walking REAPER's media-item list and routing through
`tm:bindTake` to swap mm + cm together when work has to happen on a take
other than the active one.

## Why it exists

A swing composite lives in the project-tier swing library (one
definition, shared by every take that references it by name). But the
intent ppqs of events authored against that composite are baked into
each take's MIDI. When a user drags a slider in `swingEditor`, the
active take stays in sync via the `configChanged → tm:markSwingStale
→ tm:rebuild` step 4.7 chain; every *other* take that references the
same swing falls behind.

`sequenceManager` closes that gap. On slider release (any of the six
write paths in `swingEditor`), it walks the project, finds takes whose
events still reference the edited swing name, and binds each via
`tm:bindTake(opts.markSwingStale=true)` — the post-load rebuild
reseats that take's raw from ppqL under the edited composite, then
restores the original take.

## Discovery — caching the per-take usedSwings set

The naive answer to "which takes use swing X?" is to walk every event
of every take. Cheap on a small project, painful at scale. Instead,
`tm:rebuild` projects the union of authoring swing names found across
the take's events into take-tier `usedSwings`. `sequenceManager` reads
that table directly via `cm:readTakeKey` — no mm/cm context disturbance,
no per-event scan at discovery time.

The cache is populated lazily: a take that has never been opened in
continuum has no projection yet and is invisible to `takesUsing`. This
is an accepted bootstrap caveat — the projection backfills the first
time the user binds the take. Revisit if it becomes a real friction.

## Why the bind primitive lives on tm

A take swap touches mm (event store) and cm (per-take config). They
must move together: a tm rebuild that reads a foreign mm against the
original cm (or vice versa) can mis-grow `extraColumns` and corrupt
configuration. cm broadcasts `configChanged` on context change, which
drives both tm and vm rebuilds, so the natural ordering — `cm:setContext`
then `mm:load` — fires a stale rebuild between them.

`tm:bindTake` makes the swap atomic. tm holds a private `bindingTake`
flag; while set, its own `configChanged` subscriber suppresses
`tm:rebuild`. cm can fire freely (chrome's colour-cache wipe is
harmless), then `mm:load` runs and drives a single coherent rebuild
downstream. vm participates implicitly because it rebuilds *only* on
tm's `rebuild` signal — it no longer listens directly to
`configChanged` for rebuild purposes, which closes a long-standing
double-fire race.
