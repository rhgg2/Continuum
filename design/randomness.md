# Design — Randomness (displacement only)

Status: vague, pre-design. Direction settled; mechanism deliberately open.
Scope: **displacement noise only.** Random *generation* (Poisson events,
dropout, density) is explicitly out — see "Excluded" below.

## Vocabulary

- **Displacement noise** — a perturbation of an event that already
  exists: time jitter, velocity drift, pitch wander. It moves events;
  it never creates or destroys them.
- **Model** — a named parametric noise law (Brownian, Gaussian, …).
- **Seed** — the durable parameter that makes a model's output a pure
  function of intent. Not entropy.

## The one decision

Randomness is **deterministic given a stored seed**, resolved at
rebuild from durable intent — not a fresh draw per render.

This is not an aesthetic preference; it falls out of an existing
invariant. `tm:rebuild` is idempotent and fires on many unrelated
edits. Entropy in the rebuild path would reroll every event on every
unrelated keystroke. A stored seed keeps rebuild a pure function of
intent: reproducible, reswing-safe, exports identically, and re-rolls
on demand (change the seed = new dice, deterministically).

"Lucky dip" (a fresh draw per playback) is a coherent but *separate*
thing: a realisation-time effect applied below the intent line at
play/export, never in rebuild. Out of scope here; noted only so the
boundary is explicit. "Bake to raw" is likewise a deliberate terminal
freeze the user invokes, never a default — the rebuild rule makes raw
edits follow into `ppqL`, so silent baking corrupts intent.

## Where it sits in the pipeline

Displacement noise is structurally a **seed-derived delay**: a
forward-only addend applied *after* the invertible swing Shape and
excluded from the inversion path. The precedent already exists —
`delay` is a per-note forward-only nudge, an integer bijection that
never touches `ppqL`. A Brownian time jitter is `delay` computed from
`(seed, event)` instead of stored per-note. Same property, same seam
(the "caller speaks raw" bypass already serves callers who hold raw
locally).

**Hard wall:** noise must never enter the swing composite. The swing
Shape's strict monotonicity is the invariant that makes
`swing.toLogical` well-defined, and the rebuild rule's predicted-check
arm depends on that inverse to recover `ppqL` from external edits.
Noise is not monotone; composing it into the Shape breaks inversion,
and the failure mode is exactly the silent-ppqL-loss incident
`docs/timing.md` already records. Shared machinery, separate stage.

## Machinery (reuse, don't invent)

Every piece generalises a pattern already in the tree:

- A noise *model* is a named parametric entry, the way a swing *atom*
  is a named entry with metadata.
- Presets seed-only; runtime library at project scope; slots reference
  by name; nil is identity — the swing/tuning slot-registry pattern,
  verbatim.
- Seed is per-slot, and naturally per-group-**instance**: duplicated
  or cascaded material then varies instead of repeating identically,
  dovetailing with the group-instance model.

So: one model registry, one slot/seed mechanism, one new pipeline
stage (a forward-only displacement after swing), and the wall keeping
it out of the invertible Shape.

## Excluded

Random **generation** — Poisson event spray, dropout, density,
stutter — is deliberately not designed here. It has no inverse and
changes cardinality, so it is a different genus: seed-derived
synthesised events marked derived/fake and regenerated each rebuild,
the species absorbers and synthesised PCs already are. It also forces
a real question (do generated events participate in column allocation
and collision, or are they a pure overlay?) that this pass will not
answer. Kept out so the displacement model stays small and shippable.

## Open

- Which quantities: time and velocity are clean. **Pitch is not** —
  detune is intent and only lane 1 realises, so pitch wander must go
  into the pb realisation stream, never into authored detune. Decide
  whether pitch is in this pass at all.
- Slot scope: take-wide, per-column, per-group-instance, or several.
- Model set for v1 (Brownian is the motivating case).
