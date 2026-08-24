# FX catalogue — a taxonomy Continuum owns, seeded from what REAPER records

> opened: 2026-08-24 · status: working design; not started

**Continuum holds a catalogue of the installed plugins: a nested
taxonomy over a per-format stable identity, in which a plugin may be
hard-linked in several places. It is seeded from what REAPER records,
thereafter authored in place, and the picker browses it.**

## Identity

1. A **catalogue key** names one plugin, and is unchanged by an update
   that moves the plugin's files.

1. A key is derived from each plugin REAPER reports as installed, from
   the name and the **ident** reported with it.

1. For JS, AU and CLAP the key is the ident, none of which changes
   under an update. A JSFX ident is a path relative to the effects
   directory, an AU ident is `Vendor: Name`, and a CLAP ident is the
   plugin's reverse-DNS id.

1. A VST ident is an absolute path, which an update may change. A VST's
   key is its file's base name together with the reported name, since
   one file may expose several plugins under a single base name.

1. That base name is spelled as REAPER spells it, with spaces written
   as underscores. REAPER's own files key a VST plugin that way.

1. The installed set is re-read while Continuum runs, so a plugin
   installed meanwhile is keyed like any other.

1. A key matching nothing installed is **unresolved**.

## The catalogue

1. The **catalogue** maps a catalogue key to an **entry**, and is
   global (`docs/dataStore.md`).

1. An entry carries category paths, a favourite flag, traits, audio
   ports, a developer name and a usage score. These are independent: an
   entry may carry any of them and lack the rest.

1. An entry under an unresolved key stands, and can be relinked.

## The taxonomy

1. An entry carries a set of **category paths**, each a sequence of
   names written with `/` between them. `Effects/Reverb/Plate` names a
   path three deep.

1. A plugin filed under more than one path is **hard-linked**: each
   path is a full membership, and none is primary.

1. The **category list** holds three kinds of thing:

   - every path an entry names, with those paths' prefixes — `Effects`
     and `Effects/Reverb` wherever `Effects/Reverb/Plate` is;
   - paths nothing is filed under, so one can be made before it is
     filled;
   - **unfiled**, which is no path but stands in the list beside them.

1. A **place** is an entry in the category list.

1. Renaming a path rewrites it in every entry naming it, in the
   category list, and in its descendants. Moving a path is renaming it
   under a new parent.

## Unfiled

1. A plugin is unfiled where its key has no entry, or where its entry
   carries no category path.

1. A newly installed plugin is unfiled.

## Traits

1. An entry's **traits** are three facts about the plugin: whether it
   accepts MIDI (**midi in**), whether it emits MIDI (**midi out**),
   and whether it is an **instrument**.

1. REAPER marks an instrument with a trailing `i` on its format prefix
   — `VST3i`, `VSTi`, `AUi`, `CLAPi`. An instrument accepts MIDI.

1. A JSFX's midi in and midi out come from its description: it accepts
   MIDI where it calls `midirecv`, and emits MIDI where it calls
   `midisend` or `midisyx`.

1. Whether a plugin of any other format emits MIDI cannot be read, and
   is authored.

1. Traits resolve authored over parsed over the mark.

1. Where nothing resolves them, midi in and midi out are taken as
   present, and instrument as absent.

## Probing

1. A plugin's **audio ports** are its counts of audio ins and outs,
   known only from an instance. An entry holds them.

1. Instantiating a plugin writes its audio ports into its entry, so
   ordinary use fills them in.

1. A **probe** instantiates a chosen set of plugins to write their
   ports without waiting for use.

1. A plugin whose entry holds no audio ports is **unprobed**.

## Usage

1. An entry's **usage score** orders it against other plugins, higher
   first. A score never filters.

1. Instantiating a plugin **bumps** its score. A bump advances the
   catalogue's use counter by one, decays the entry's score by the uses
   elapsed since its last bump, and adds one.

1. Decay counts uses, not time. A month in which nothing is
   instantiated costs an entry nothing.

1. Parameter frecency (`docs/dataStore.md`) keys on the catalogue key,
   so that a plugin's parameter scores survive a relocation.

## The sources

1. A **source** is classification readable without the user authoring
   it. There are five, across two files and the idents themselves.

1. The **install tree** is the directory structure the plugins sit
   under, read from the ident. Its depth varies by installation.

1. **User categories** are `reaper-fxfolders.ini` `[category]`: one or
   more names per plugin separated by `|`, written where the user
   assigns them. `[categories]` names the categories the user created,
   and `[deleted_categories]` those hidden from REAPER's own browser.

1. **User folders** are the `[Folder<n>]` sections of the same file,
   each listing one FX-browser folder's members, indexed by id and name
   in `[Folders]`. A plugin may sit in several folders. Folder id 0 is
   `Favorites` on every installation.

1. **Derived categories** are `reaper-fxtags.ini` `[category]`: one or
   more names per plugin separated by `|`, written by REAPER at scan
   time.

1. **Developers** are `reaper-fxtags.ini` `[developer]`: one
   manufacturer name per plugin. A developer name filters, and is never
   a category path.

1. A folder item names a plugin by its ident. A category key names it
   by its ident too, except for VST, where it is the base name in
   REAPER's spelling.

1. A folder section's `Type` field gives the plugin's format.

   | Type | format |
   |---|---|
   | 2 | JS |
   | 3 | VST2 and VST3 |
   | 5 | AU |
   | 7 | CLAP |

1. A section that does not parse is skipped, and the rest is read.

## Import

1. **Import** reads chosen sources into the catalogue. It sets the
   catalogue up, and is run when the user asks.

1. Each source is taken or declined on its own. Import states each
   source's coverage and how many distinct names it yields, so the
   choice among them rests on what a given installation holds.

1. Import runs in one of two modes. **Augment** adds, and **replace**
   overwrites.

1. A source's plugin references resolve to catalogue keys against the
   installed set. References resolving to nothing are dropped, and
   their number is stated.

1. An install-tree directory becomes a category path, one segment per
   directory below the format's plugin root.

1. A category name becomes a category path, split on `/`.

1. A folder name becomes a category path the same way. Membership of
   folder id 0 sets the favourite flag instead.

1. The names in `[categories]` enter the category list, whether or not
   anything is filed under them.

1. A developer name is written to the entry, and files nothing.

## The seed nesting

1. The **seed nesting** maps derived category names to category paths,
   and ships with Continuum. It places names such as `Reverb` and
   `Compressor` under broader ones.

1. Importing derived categories applies the seed nesting, filing a
   plugin at the nested path in place of the bare name.

1. A name the seed nesting does not hold is filed at its bare name.

1. The seed nesting leaves no trace beyond the paths it writes, which
   are renamed as any other path is.

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

1. Whether a JS category key carries the plugin's subdirectory. A
   folder item does, and the join needs to know whether a category key
   agrees.

1. Whether REAPER's plugin cache (`reaper-vstplugins*.ini`,
   `reaper-auplugins*.ini`) is read, and for what. It carries no
   classification, but maps a base name to a display name, a vendor and
   the instrument mark for every plugin ever scanned, including those
   no longer reported as installed.

1. Ident forms on Windows and Linux, where a VST ident is a backslash
   path and AU does not exist.

1. What relinking an unresolved entry looks like, and whether a
   relinked key can be inferred from the entry's other facts.

1. Where the catalogue is edited from — filing a plugin, making a
   path, authoring a trait, running a probe — and whether that surface
   is a page of its own.

1. What a probe costs over a large installation, and whether it runs
   over everything or only over what the user asks for.

1. Whether the picker offers a filter the user states — four audio ins
   and a compressor, to find a plugin to sidechain into.
