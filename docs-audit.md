# docs audit ledger

A record of when each doc in `docs/` was last read against the code
and found true. Each row holds the doc's blob hash at that moment and
the commit HEAD was on. Staleness is then read off the commits since
that pass, and what matters is which side of the pair a commit
touched:

- **the module but not the doc** — the subject has shifted and the doc
  has not followed. This is the alarm worth acting on.
- **the doc but not the module** — a prose pass, no change of subject.
- **both at once** — the doc was kept in step, and needs no attention
  beyond a re-read when convenient.

A mechanical sweep across the tree, a comment-hygiene pass say, counts
as the module moving, so the report prints the subjects of the
unaccompanied commits and leaves the judgement to a human.

Only passes are recorded. Which docs exist, how big they are, and
which have never been audited are read off the tree by
`tools/docs_audit.py`, which prints the states and the unaudited docs
by ascending size. `tools/docs_audit.py pass <doc>.md` stamps a row.

These are reference material rather than Continuum's own docs, and are
not audited:

- `reaper_midi_routing.md`
- `reaper_routing_for_reascript.md`

## passes

| doc                    | blob         | passed at |
|------------------------|--------------|-----------|
| CONVENTIONS.md         | 7ac81e919c0e | f5b5a21d  |
| continuum.md           | c10c4e8479a4 | 7eadc139  |
| coordinator.md         | d5ee7d4f5048 | 7eadc139  |
| curveEditor.md         | 411abdf9c84b | 02202016  |
| dataStore.md           | 9361a3a71de9 | 1062211b  |
| fs.md                  | 7a9dfbdec4af | 7eadc139  |
| masterMix.md           | 559e5c18b304 | 40be12ec  |
| routingManager.md      | d4caf1a9f867 | 7eadc139  |
| samplePage.md          | 6fd4d7aa7437 | 3559cfe6  |
| sampleView.md          | 8c9e31cfc88e | 5470573f  |
| scratch.md             | 4287cb0592f7 | 5470573f  |
| viewContext.md         | c8ab5e6cea8f | 7eadc139  |
| voicing.md             | fd6db5526687 | 9b99c9a2  |

The five stamped at `7eadc139` were marked done in the tracker's first
commit, so that is the earliest point their pass can be pinned to.
