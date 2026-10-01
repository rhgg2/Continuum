# FX catalogue — plan

> source: `design/fx-catalogue.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Keys and entries** (§ Identity, § The catalogue, § Usage 4)
   — the per-format catalogue key with REAPER's VST base-name spelling,
   the installed set re-read and indexed by key, and parameter frecency
   rekeyed onto the catalogue key. — landed 2026-09-30, 2 commits.
2. **Phase 2 — Facts on an entry** (§ The catalogue, § Traits, § Probing
   1–2, § Usage 1–3) — the catalogue as a global ds key with unresolved
   entries standing, landing with its first writers: audio ports written
   on instantiation, the use-counted bump, and traits resolved authored
   over parsed JSFX over the format mark. The probe waits on the surface
   the catalogue is edited from (§ Open). — landed 2026-10-01, 2 commits.
3. **Phase 3 — Taxonomy and import** (§ The taxonomy, § Unfiled, § The
   sources, § Import, § The seed nesting) — category paths with the list
   and rename, parsers for the install tree and the two ini files, import
   with its per-source coverage in augment or replace mode, and the
   shipped seed nesting. The model only: import and rename are reached
   through the bridge, and their surface waits with the probe's.
   ← in flight
4. **Phase 4 — The picker** (§ The picker, § The filtering seam) — the
   wiring picker grouped by place with favourites above and unfiled last,
   usage and in-project ordering within a place, and the candidate
   predicate over the four contexts, with `new` the one opened today.

## Landed  (newest first; prune below ~4)

- 2026-10-01 fxCatalogue: add category paths, standing paths and the category list (design § The taxonomy)
- 2026-10-01 fxCatalogue: resolve a plugin's traits, authored over parsed over mark (§ Traits)
- 2026-09-30 wiring: record a plugin's ports and usage in the catalogue on add (§ The catalogue, § Probing 1–2, § Usage 1–3)
- 2026-09-30 tracker: key parameter frecency on the catalogue key (§ Usage 4)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **fxCatalogue: read the sources, resolved to catalogue keys** (§ The
  sources, § Import 2, 4–5) — an ini reader that skips a section it
  cannot parse; `reaper-fxfolders.ini` `[category]`, `[categories]`,
  `[Folders]` and `[Folder<n>]`, each item's format from its `Type`;
  `reaper-fxtags.ini` `[category]` and `[developer]`; the install tree
  from each installed ident, one segment per directory between its
  root and its file. The VST roots are the architecture's `vstpath`
  key in `reaper.ini`, split on `;` with `~` expanded, and the JS root
  is `Effects/`. Each source yields names per catalogue key, with its
  coverage of the installed set, its count of distinct names and its
  count of dropped references. A JS category key is a file name, and
  resolves to every JSFX carrying it. Ini fixtures under
  `tests/fixtures`.
- **fxCatalogue: import the chosen sources** (§ Import) — each source
  taken or declined; category and folder names split on `/` into
  paths; folder id 0 setting the favourite flag; developer names
  written and filing nothing; `[categories]` names made standing
  paths. Augment adds to what the catalogue holds. Replace first
  clears every entry's paths, favourite flag and developer name, and
  the standing paths, and leaves ports, usage and traits.
- **fxCatalogue: the seed nesting** (§ The seed nesting) — a shipped
  table from derived names to paths, placing names such as `Reverb`
  and `Compressor` under broader ones; applied when derived categories
  are imported, a name it lacks filed at its bare name. The names
  REAPER derives on the development installation run from `Synth`,
  `Distortion`, `Dynamics` and `Reverb` down to `Tuner` and `Organ`.

