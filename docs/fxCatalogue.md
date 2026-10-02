# fxCatalogue

**The installed plugins, each under a catalogue key that names one
plugin across an update moving its files, and a catalogue holding
facts about each and the paths they are filed under.** Its only state is a session memo of parsed JSFX
descriptions (§ Traits). It re-reads REAPER's installed set on every
call, and the catalogue is a dataStore key.

## The catalogue key

1. A **catalogue key** names one plugin, and is unchanged by an update
   that moves the plugin's files.

1. A key is derived from each plugin REAPER reports as installed, from
   the name and the **ident** reported with it. The name's prefix
   before `:` gives the plugin's format.

1. For JS, AU and CLAP the key is the ident, none of which changes
   under an update. A JSFX ident is a path relative to the effects
   directory, an AU ident is `Vendor: Name`, and a CLAP ident is the
   plugin's reverse-DNS id.

1. A VST ident is an absolute path, which an update may change. A VST's
   key is its file's base name, with the `<id` suffix REAPER adds to
   the ident where one file exposes several plugins.

1. That base name is spelled as REAPER spells it, with every character
   other than a letter, a digit or `.` written as `_`. REAPER's own
   files key a VST plugin that way.

## An instance's key

1. An instance reports its VST ident with the `<id` suffix whether or
   not its file exposes several plugins. A VST3 instance's ident also
   ends in the plugin's class id, written after `{`.

1. An instance's key is thus the installed key its ident matches: the
   base name with the `<id` where an installed key carries it, and
   without it otherwise.

1. An instance reporting an empty ident has no key.

1. Parameter frecency holds its scores under an instance's key
   (`docs/trackerRender.md` § Parameter sections).

## The installed set

1. The installed set is re-read on every call, with no memo, so a
   plugin REAPER reports mid-session is keyed like any other.

1. A re-read costs little, since REAPER builds the list on the first
   call and serves it from memory after
   (`docs/reaper_routing_for_reascript.md` § 6.2).

1. A key matching nothing installed is **unresolved**.

## The catalogue

1. The **catalogue** maps a catalogue key to an **entry**. It is a
   global dataStore key (`docs/dataStore.md`), so one catalogue serves
   every project.

1. An entry holds facts about its plugin: its audio ports, its usage
   score, any authored traits, its category paths (§ The taxonomy), a
   favourite flag and a developer name.
   The facts are independent. An entry may carry any of them and lack
   the rest, and a write to one leaves the others alone.

1. Adding a plugin to the wiring graph (`docs/wiring.md`) is a **use**
   of it, and writes to its entry. A plugin Continuum adds for its own
   plumbing is not a use.

1. The catalogue sits outside undo. Undoing the add of a plugin leaves
   the use it recorded in place.

1. Nothing prunes the catalogue. An entry under an unresolved key
   stands, and keeps its facts.

## Audio ports

1. A plugin's **audio ports** are its counts of stereo audio ins and
   outs, half its pin counts. They are known only from an instance.

1. A use writes the instance's audio ports into the plugin's entry,
   overwriting any it held. Ordinary use thus fills them in.

## Traits

1. A plugin's **traits** are three facts about it: whether it accepts
   MIDI (**midi in**), whether it emits MIDI (**midi out**), and
   whether it is an **instrument**.

1. REAPER marks an instrument with a trailing `i` on its format prefix
   — `VST3i`, `VSTi`, `AUi`, `CLAPi`. An instrument accepts MIDI. An
   instance's mark is read from the type it reports, which carries the
   same prefix.

1. A JSFX's midi in and midi out come from its description: it accepts
   MIDI where it calls `midirecv`, and emits MIDI where it calls
   `midisend` or `midisyx`. The same parse gives its **bus awareness**,
   a declaration of `ext_midi_bus = 1` outside a comment.

1. A description is parsed once per session, and the parse is
   remembered by the JSFX's path.

1. Whether a plugin of any other format emits MIDI cannot be read, and
   is authored on its entry.

1. Each trait resolves on its own, authored over parsed over the mark.

1. Where nothing resolves them, midi in and midi out are taken as
   present, and instrument as absent. A JSFX whose description cannot
   be read resolves the same way.

1. The resolved traits carry bus awareness alongside, which only a
   parse gives.

1. routingManager resolves the traits of every fx record it reads
   (`docs/routingManager.md` § Read cost). A read reads the catalogue
   once, and walks the installed set at most once, for the first VST
   it keys.

## Usage

1. An entry's **usage score** orders it against other plugins, higher
   first. A score never filters.

1. A use **bumps** the plugin's score. A bump advances the catalogue's
   use counter by one, decays the entry's score by the uses elapsed
   since its last bump, and adds one.

1. Decay counts uses across the whole catalogue. A month in which
   nothing is instantiated costs an entry nothing.

1. Each use scales a score by 0.98, so a score halves over about 34
   uses of other plugins.

## The taxonomy

1. An entry carries a set of **category paths**, each a sequence of
   names written with `/` between them. `Effects/Reverb/Plate` names a
   path three deep.

1. A name is never empty. It is kept as given, so `Reverb` and
   `reverb` are two names.

1. **Filing** a plugin under a path adds the path to its entry, and
   **unfiling** removes it. An entry left with no path keeps its other
   facts.

1. A plugin filed under more than one path is **hard-linked**: each
   path is a full membership, and none is primary.

1. A **standing path** is made on its own, as a place to file into.
   The catalogue holds the standing paths beside its entries. A
   standing path stands whether or not anything is filed under it.

1. The **category list** holds three kinds of thing:

   - every path an entry names, with those paths' prefixes — `Effects`
     and `Effects/Reverb` wherever `Effects/Reverb/Plate` is;
   - every standing path, with its prefixes;
   - **unfiled**, which is no path but stands in the list beside them.

1. The list orders its paths name by name, ignoring case, so a path
   follows its parent. Two paths differing only in case order by their
   bytes. Unfiled comes last.

1. A **place** is an entry in the category list.

1. A plugin is unfiled where its key has no entry, or where its entry
   carries no category path. A newly installed plugin is thus unfiled.

1. Renaming a path rewrites it in every entry naming it, among the
   standing paths, and in its descendants. A path renamed onto one that
   exists merges with it.

1. Moving a path is renaming it under a new parent. A parent listed
   only as a prefix of the moved path leaves the list with it.

1. Filing, unfiling and renaming never read the installed set, so a
   path held by an entry under an unresolved key stands like any other.

## The sources

1. A **source** is classification readable without the user authoring
   it. There are five, across two of REAPER's files and the idents
   themselves. Reading them writes nothing.

1. The **install tree** is the directory structure the plugins sit
   under, read from the ident. Its depth varies by installation.

1. A VST's plugin roots are the paths each VST path key in
   `reaper.ini` lists, one key per architecture. A JSFX's root is the
   effects directory. A root holds a plugin only as a whole directory,
   so `Plug-Ins/VST` does not hold what sits under `Plug-Ins/VST3`.

1. Where roots nest, a plugin sits under the deepest one holding it.

1. A plugin's install-tree name is its directories below its root,
   joined by `/`. A plugin directly at a root has none, and neither has
   a VST under no root. An AU or CLAP ident names no directory, so
   neither format has an install tree.

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

1. A folder item names a plugin by its ident. A category key names an
   AU or CLAP plugin by its ident, a VST by its base name in REAPER's
   spelling, and a JSFX by its file name without the subdirectory.

1. A folder section's `Type` field gives the plugin's format.

   | Type | format |
   |---|---|
   | 2 | JS |
   | 3 | VST2 and VST3 |
   | 5 | AU |
   | 7 | CLAP |

1. A **smart folder** holds its filter in place of members, as one
   item of `Type` 1048576. That item names no plugin.

1. A section holding a line that does not parse is skipped, and the
   rest of the file is read. A missing file reads as empty, so its
   sources hold nothing.

1. A source's plugin references resolve to catalogue keys against the
   installed set. A reference matching no key exactly resolves to those
   matching it ignoring case, since REAPER's files spell one plugin in
   more than one case. A reference resolving to nothing is **dropped**.

1. A JS category key naming a file name several JSFX share resolves
   to each of them. A key matching exactly takes precedence over a file
   name, and a file name over a match ignoring case.

1. A name with an empty name in its path is not kept (§ The taxonomy),
   so the empty name after a trailing `|` yields nothing. It is not a
   dropped reference.

1. Each source states three counts: the installed plugins it
   **covers**, the distinct names it yields, and the references it
   dropped. A plugin is covered where the source gives it a name, and
   for user folders also where it is a favourite.

## Import

1. **Import** writes chosen sources (§ The sources) into the
   catalogue. It is run when the user asks.

1. Each source is taken or declined on its own. Its counts are stated
   before the choice, so the choice rests on what a given installation
   holds.

1. An entry's **classification** is its category paths, its favourite
   flag and its developer name.

1. Import runs in one of two modes. **Augment** adds to what the
   catalogue holds. **Replace** first clears every entry's
   classification and every standing path, whichever sources are
   taken.

1. Replace leaves an entry's other facts in place. An entry under an
   unresolved key is cleared like any other, and stands.

1. An install-tree directory becomes a category path, one name per
   directory below the plugin root.

1. A category name becomes a category path, split on `/`. A folder name
   becomes one the same way.

1. Membership of folder id 0 sets the favourite flag, and files
   nothing.

1. The names in user `[categories]` become standing paths, so they are
   listed whether or not anything is filed under them.

1. A developer name is written only to an entry holding none, and
   files nothing. Under replace the clear comes first, so the taken
   developers overwrite.

1. Where several developer names resolve to one key, the
   lowest-sorting by bytes is written.
