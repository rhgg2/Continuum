# FX catalogue — a taxonomy Continuum owns, seeded from what REAPER records

> opened: 2026-08-24 · status: in flight — plan/fx-catalogue.md,
> phase 3 (taxonomy and import).

**Continuum holds a catalogue of the installed plugins: a nested
taxonomy over a per-format stable identity, in which a plugin may be
hard-linked in several places. It is seeded from what REAPER records,
thereafter authored in place, and the picker browses it.**

## Identity

Landed in `docs/fxCatalogue.md`.

## The catalogue

1. The catalogue, its entries and their independent facts: landed in
   `docs/fxCatalogue.md` § The catalogue.

1. An entry under an unresolved key can be relinked.

## The taxonomy

Landed in `docs/fxCatalogue.md` § The taxonomy.

## Unfiled

Landed in `docs/fxCatalogue.md` § The taxonomy.

## Traits

Landed in `docs/fxCatalogue.md` § Traits.

## Probing

1. Audio ports and their write on use: landed in `docs/fxCatalogue.md`
   § Audio ports.

1. A **probe** instantiates a chosen set of plugins to write their
   ports without waiting for use.

1. A plugin whose entry holds no audio ports is **unprobed**.

## Usage

Landed in `docs/fxCatalogue.md` § Usage, and parameter frecency in
§ An instance's key.

## The sources

Landed in `docs/fxCatalogue.md` § The sources.

## Import

Landed in `docs/fxCatalogue.md` § Import.

## The seed nesting

Landed in `docs/fxCatalogue.md` § The seed nesting.

## The picker

1. The picker offers the installed plugins under the category list, a
   plugin appearing at each place its entry names.

1. Favourites form a further place, above the list.

1. Unfiled comes last.

1. Within a place, plugins sort by usage score.

1. A plugin already in the project sorts above one that is not.

1. Typing narrows the list by name.

## The filtering seam

1. The picker opens with a **context**: the graph role the chosen
   plugin will take (`docs/wiring.md`). A plugin the context admits is
   a **candidate**, and only candidates are offered.

1. There are four contexts.

   - **new** — the plugin stands alone on the canvas. Admits
     instruments.
   - **splice** — the plugin is inserted into a wire. Admits plugins
     carrying both an in and an out of that wire's type.
   - **branch** — the plugin is fed from a port. Admits plugins
     carrying an in of that port's type.
   - **replace** — the plugin takes another's place. Admits plugins
     whose ports cover the wires the other carries.

1. Candidacy over MIDI reads the entry's traits, and candidacy over
   audio its ports. An unprobed plugin passes every audio test.

1. Absent a context, every installed plugin is a candidate.

## Open

1. Whether typing gains a token grammar — path, developer, trait,
   favourite — in place of separate controls.

1. Whether the shared typeahead picker (`docs/chrome.md` § Picker)
   serves this list, given that it groups rows already but is built for
   smaller ones.

1. Whether `[deleted_categories]` should suppress a name at import.
   The list records the user's own hiding, which bears on the user
   categories and the derived ones differently.

1. Whether an entry's developer name is worth holding, given that the
   name REAPER reports already carries it.

1. How LV2 is handled. A category key may name an LV2 plugin by URI
   while `EnumInstalledFX` reports no LV2 at all, so classification can
   exist for plugins that cannot be offered.

1. Whether REAPER's plugin cache (`reaper-vstplugins*.ini`,
   `reaper-auplugins*.ini`) is read, and for what. It carries no
   classification, but maps a base name to a display name, a vendor and
   the instrument mark for every plugin ever scanned, including those
   no longer reported as installed.

1. How an AU whose files are deleted is treated. REAPER's AU cache
   (`reaper-auplugins*.ini`) still reports it as installed, and an
   instance of it reports an empty ident.

1. Ident forms on Windows and Linux, where a VST ident is a backslash
   path and AU does not exist.

1. What relinking an unresolved entry looks like, and whether a
   relinked key can be inferred from the entry's other facts.

1. Where the catalogue is edited from — filing a plugin, making a
   path, authoring a trait, running a probe — and whether that surface
   is a page of its own.

1. Whether a path can be deleted, and what becomes of the plugins
   filed under it.

1. What a probe costs over a large installation, and whether it runs
   over everything or only over what the user asks for.

1. Whether the picker offers a filter the user states — four audio ins
   and a compressor, to find a plugin to sidechain into.
