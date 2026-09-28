# FX catalogue — plan

> source: `design/fx-catalogue.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Keys and entries** (§ Identity, § The catalogue, § Usage 4)
   — the per-format catalogue key with REAPER's VST base-name spelling,
   the installed set re-read and indexed by key, and parameter frecency
   rekeyed onto the catalogue key.  ← in flight
2. **Phase 2 — Facts on an entry** (§ The catalogue, § Traits, § Probing,
   § Usage 1–3) — the catalogue as a global ds key with unresolved
   entries standing, landing with its first writers: traits resolved
   authored over parsed JSFX over the format mark, audio ports written on
   instantiation, the use-counted bump, and a probe over a chosen set.
3. **Phase 3 — Taxonomy and import** (§ The taxonomy, § Unfiled, § The
   sources, § Import, § The seed nesting) — category paths with the list
   and rename, parsers for the install tree and the two ini files, import
   with its per-source coverage in augment or replace mode, and the
   shipped seed nesting.
4. **Phase 4 — The picker** (§ The picker, § The filtering seam) — the
   wiring picker grouped by place with favourites above and unfiled last,
   usage and in-project ordering within a place, and the candidate
   predicate over the four contexts, with `new` the one opened today.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- shared: key each installed plugin, and re-read the set on demand
  (§ Identity 1–7) — a new shared module derives the key from a
  reported name and ident. JS, AU and CLAP take the ident, and VST
  takes its file's base name — spaces written as `_` — with the reported
  name. The module enumerates `EnumInstalledFX` on each call into an
  index from key to name, ident and format, and answers whether a key
  resolves. `rm:installedFx` delegates to it, and drops its memo and
  its fixed-at-runtime contract, so each picker open reads the set
  afresh. The spec covers one ident per format, one VST file exposing
  two plugins, and a plugin appearing between two reads;
  `wm_installed_fx_spec` follows the delegation.
- tracker: key parameter frecency on the catalogue key (§ Usage 4) —
  the shared module derives an instance's key from its `fx_ident` and
  `fx_name`, and `pa` reads and bumps `paramFrecency` under that key in
  place of the raw ident. Scores held under an absolute VST path are
  orphaned, with no migration. The spec shows a VST's scores surviving
  a change of its ident's directory.
