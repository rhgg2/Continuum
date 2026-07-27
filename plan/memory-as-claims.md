# memory-as-claims — plan

> source: `design/memory-as-claims.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 config: fold the wonder ledger in as open claims (D11, D15)
- 2026-07-27 config: fold the store to ten claims, MEMORY.md as the claim index
- 2026-07-27 config: retire misfiled memory to docs and CLAUDE.md (D6)
- **2026-07-27 · `48c1abf`** — the move completed: `autoMemoryDirectory` in

## Now

(empty — the open end exists; run /plan-next to promote the decay rule, D10)

## Unfiled

(nothing unfiled)

## World

- [2026-07-19] Does REAPER's MIDI_Sort stable-sort simultaneous events? The SetAllEvts stranding fix leans on it; the docs don't say. reaper_eval could answer this empirically.
- [2026-07-19] EEL2 is case-insensitive AND unscoped at top level — what interpreter-history decision led there? Cockos forum archaeology might tell.
- [2026-07-19] Why do trackers historically number rows in hex? Amiga-era memory-address habit, or a real ergonomic win at 16 rows per beat?
- [2026-07-19] Lua's gsub-with-escaped-pattern idiom (used in the wonder ledger's own `done` command) is everywhere and always awkward. Is there a cleaner plain-substring replace idiom the community has settled on?

## Build

- [2026-07-19] A blunt blanket op can silently consolidate several unrelated upstream responsibilities: computeFxWindows's column sort was really repairing four independent disorder sources (staleSwing reseat, externals, the raw->logical flip, PA projection), each invisible until a temporary 'assert the invariant on every rebuild' scaffold isolated them one at a time. Where else in the tm rebuild does one blanket pass mask coupling like this? A deliberate assert-and-see-what-breaks sweep over other invariants (columns sorted, dirt monotone, uuids stable) might surface more.
- [2026-07-19] Continuum's detune-is-intent / pb-is-realisation split looks isomorphic to MPE's per-note-channel model. Could the realisation layer target MPE with almost no change to intent data?
- [2026-07-19] The sample-similarity spike chose an AHD-warped envelope feeding scattering. On percussive one-shots specifically, does scattering actually beat plain MFCC, or did it win on the sustained cases?
````

`## Unfiled` lands empty because this migration is itself the first filing pass
(D15); it is the landing zone for everything jotted after. No `## Us` section,
by contrast — none of the seven is about how we work, and a standing empty
subject heading invites filling to fill it.

### Append to `.claude/agent-memory/MEMORY.md` (currently ends at line 38)

````markdown

## Open

*Not claims yet — noticed and set aside, the end where claims enter*

- [Open questions](open.md) — tm-rebuild blanket passes, MIDI_Sort stability, EEL2 history, MPE isomorphism, hex rows, scattering vs MFCC, Lua gsub
````

One index line rather than an *Open* tier inside each of World / Build / Us: the
other three sections are subjects and this one is a standing, which is a real
asymmetry, but three index lines pointing at one file costs more than it
explains. Revisit if `open.md` grows past a screen.

### The one entry that is nearly a finding

The `computeFxWindows` bullet is half-observed already — the blanket-op
mechanism is confirmed by an incident, and only its "where else in the tm
rebuild?" tail is open. It enters as `open` regardless: promoting on the
strength of the entry that noticed it is exactly the tally D13 rejects. Flagged
here because it is the nearest to graduating when the first rising-sea pass runs.

### Not in scope

`~/.claude/wonder/` is untouched — `ledger.md` and `wonder.lua` both stay put
until the machinery items land. No seeder tool, no skill registration, no edit
to MEMORY.md's preamble (that is D12, item 5).

### Done looks like

No spec and no suite involvement — this is `config:` scope, prose only, with no
Lua and no observable behaviour to go red on first. Evidence instead:
`.claude/agent-memory/open.md` exists with seven bullets under World and Build;
MEMORY.md carries the `## Open` section; `git status` shows exactly those two
paths; `~/.claude/wonder/ledger.md` is byte-identical to its current state.
Commit headline scope `config:`.

## Queued (one-liners)

1. Decay rule (D10) into the store's conventions: a `us` shape that has stopped
   firing falls back toward `open` rather than sitting at `load-bearing` —
   measured by counts and dates, never by re-extracting text.
   `us_reconstruction_vs_retrieval.md` already states its own decay in prose;
   this generalises it.
2. `wonder.lua` into the repo as the `open.md` seeder (D11) — `add` appends to
   `## Unfiled` and asks nothing (D15); `pick` and `done` retargeted at the
   store's file. Siting decided then: `tools/` alongside `comment_hygiene.py`,
   or under `.claude/`.
3. `rising-sea.md` registered as a skill in `.claude/skills/` (D13), carrying
   the filing pass that empties `## Unfiled`, and `~/.claude/wonder/` deleted
   once nothing there is still load-bearing.
4. Write the loop into the workflow (D12, D14): the narrative leaves MEMORY.md
   for the workflow surface, and jot → chase → rising-sea → decay is documented
   there, including the standing permission it grants.
