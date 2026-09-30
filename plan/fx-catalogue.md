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
   the catalogue is edited from (§ Open).  ← in flight
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

- 2026-09-30 wiring: record a plugin's ports and usage in the catalogue on add (§ The catalogue, § Probing 1–2, § Usage 1–3)
- 2026-09-30 tracker: key parameter frecency on the catalogue key (§ Usage 4)
- 2026-09-30 wiring: key each installed plugin, re-read the set on every call (§ Identity)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **Traits** (§ Traits) — fxCatalogue resolves a plugin's midi in, midi
  out and instrument authored over parsed over the mark. Authored comes
  from the entry's `traits`, which only a ds write sets for now. Parsed
  comes from a JSFX description: midi in on `midirecv`, midi out on
  `midisend` or `midisyx`. The mark is the `i` ending the format prefix,
  and an instrument accepts MIDI. Where nothing resolves, midi in and out
  are present and instrument absent. wm's JSFX parse
  (`parseJSFXMidiTraits`, `readJSFXContent` and the session memo) moves
  into fxCatalogue, with `busAware` read from the same parse. wm's
  `fxMidiPorts` and its two `recv` reads go through the resolved traits,
  so a native plugin's authored midi out reaches its node's midi ports.
  Spec: the resolution order in `fxCatalogue_spec`; wm's existing
  midi-port specs pass unchanged.

