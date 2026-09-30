# fxCatalogue

**The installed plugins, each under a catalogue key that names one
plugin across an update moving its files.** The module is stateless,
and re-reads REAPER's installed set on every call.

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
