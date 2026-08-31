# spec audit ledger

A record of when each spec in `tests/specs/` was last read against the
standard of the coding skill, `.claude/skills/coding/SKILL.md`. Each
row holds the spec's blob hash at that moment and the commit HEAD was
on.

A spec has no single subject — each exercises a swathe of core
modules, so nearly every commit touches one — and the audit is about
the spec's own text. So a spec goes stale when the spec itself moves,
and `tools/audit.py specs` reports by how much, and in which commits.
Which specs exist, their size and their assertion density are read off
the tree.

## method

Per spec, in order:

1. **Read the header against the docs.** Specs should pin a model and
   the header should describe what is pinned, not a plan phase, a
   commit, or a "not yet". Check what `docs/` and the module's
   `--contract:`/`--invariant:` annotations say now (`map_query` with
   `kind='ann'`). Non model-based framings usually reach the case
   names too.

1. **Give every case its sentence** — the doc line or annotation it
   pins. A case with no sentence is either under-documented model or a
   pinned implementation; decide which before touching it.

1. **Look for the three shapes.** Vacuous assertions: a loop with no
   precondition, a comparison whose sides can both be nil, an assertion
   over a batch that can be empty. Restated constants: a literal copied
   from the code rather than derived. Names that claim more than the
   scenario can exercise.

1. **Turn suspicion into evidence with `spec_perturb` before editing.**
   Break the mechanism each doubtful case names. A case that survives
   the breakage of its own mechanism is the finding; one that dies is
   vindicated and left alone. A batch of six on a filtered spec costs
   about two seconds.

1. **Edit, then re-run the same batch.** The rewrite has to kill
   everything the original killed, plus whatever it was written to
   close.

1. Stamp the pass with `tools/audit.py specs pass <spec>.lua`.

## passes

| spec                     | blob         | passed at |
|--------------------------|--------------|-----------|
| tm_fx_region_spec.lua    | f74d83c326b9 | 332446b4 |
| vm_retune_spec.lua       | 0e7ad31fbd6e | 05ad837f |
| vm_tracker_mode_spec.lua | 1dbe680827c7 | a747deec |
