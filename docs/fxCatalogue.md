# fxCatalogue

**The installed plugins, each under a catalogue key that names one
plugin across an update moving its files, and a catalogue of facts
about each.** The module holds no state of its own. It re-reads
REAPER's installed set on every call, and the catalogue is a
dataStore key.

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

1. An entry holds facts about its plugin: its audio ports and its
   usage score. The facts are independent. An entry may carry any of
   them and lack the rest, and a write to one leaves the others alone.

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
