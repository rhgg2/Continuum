# map navigation — what the maps cost to read

> opened: 2026-08-01 · status: in flight — `plan/map-navigation.md`
>
> Working design doc. The measurement below is done and is reported in
> full; it is the load-bearing part of this doc. The design that follows
> it is a proposal awaiting a plan.

## Problem

The `.map` layer answers *where does X live* well. It does not answer
*what does X call*, and inside a single file it answers almost nothing:
`trackerManager.map` lists **173 private functions and zero edges between
any of them**. `CALL_RE` (`tools/map_extract.py:72`) requires a `.` or `:`
separator, so a bare `renderUnion(...)` matches nothing at all — the
intra-file call graph is not sparse, it is absent by construction. A
second source is extracted and then discarded: `self:foo()` calls are
found and skipped at `map_extract.py:545` as "not an outbound edge",
which is true and beside the point.

The question was what to do about it, and the first answers reached for
were better *parsing* — tree-sitter or full-moon for a real AST, `luac -l
-l` for scope-resolved upvalues and field access. Both are real
capabilities. Neither turned out to be the thing.

## Why we measured instead of asking

The obvious way to choose is to ask the agent which tools it wants. That
instrument is close to worthless: it has no clock, its memory of a session
is a transcript in which a six-hop trace and a one-shot lookup look
identical, and the question comes from the person who built the tools. It
returns "pretty happy" almost regardless of the truth.

What *is* reliable is structural and already recorded. 1072 session
transcripts sit in `~/.claude/projects/`, and every tool call ever made in
this repo is in them. Crucially, **tool calls in one assistant message ran
in parallel; calls in consecutive messages are serial**, each blocked on
the last. Round-trips are the unit of cost, and they are countable.

`tools/navigation_survey.py` does the counting. Re-run it after any
tooling change — the chain histogram and the scattered-jump rate are the
numbers that should move.

## What the corpus says

494 sessions containing tool calls; 18,942 main-thread calls (subagents
excluded — they are bulk readers by design and would flatter the figures).

**Navigation is overwhelmingly serial.** 2,608 navigation runs carrying
11,888 turns. 953 runs are ≥4 dependent round-trips, and those carry
**77.7% of all navigation turns**. The deepest single run is 44
consecutive blocked turns.

**The serialism is intra-file.** Of 1,385 consecutive read-turn pairs,
**50.4% re-read the same file** at a different range. Of those:

- **81.3% are scattered jumps**, not sequential chunking
- median jump **362 lines**, p90 **1,940 lines**
- **481 jumps are backwards**, revisiting earlier code

Jumping 362 lines away and later back is call-chain following. There is no
other reading of it.

**One file dominates.** `trackerManager.lua` is 42% of all same-file
walking (295 of 698 pairs) and takes **3,292 redundant touches** across
the corpus, 4× the next file. It is 5,121 lines, 173 private functions,
78 outbound edges, zero internal ones.

**The maps are consulted, then found insufficient.** 73% of reads of a
mapped `.lua` happen after a `map_query` in the same session. Reads are
2,071 ranged against 690 whole-file, so map line numbers *are* being used
— just many of them per question.

**Incidental:** the built-in `Grep` was used **once** in the entire
corpus; `grep_window` displaced it completely. But `grep` via Bash ran
1,132 times, so shell fallback is still substantial. 380 navigation calls
came back empty, and the next move was usually shell grep (159) or another
search (109) — silence is not trusted, it is re-asked by hand.

One caveat on the instrument: **the session running the survey is inside
the corpus it surveys**, and is still being appended to. Two runs minutes
apart disagreed by 2 runs in 2,610 — the measuring session had navigated
in between. Immaterial at this scale, and worth knowing before reading a
small before/after delta as signal.

## Two traps

Both of these looked right and were not. They are recorded because the
tidy version of this design would omit them and invite the next reader
straight back in.

**Accuracy is not the bottleneck.** The investigation opened on parser
correctness — the multi-assignment limitation at `map_extract.py:578`, a
live bug where `extract_uses` splits on `--` over raw lines
(`map_extract.py:538`) so a `--` inside a string truncates the scan,
shadowing-blind alias resolution, the `ATTACH_GAP = 3` adjacency
heuristic. All real. None of them cost measurable time. A map that is 3%
more correct saves nothing; the cost is round-trips, and correctness does
not touch round-trips.

**Transitive expansion is the answer to a question nobody asked.** Once
"round-trips are the cost" is established, a tool that expands a call tree
N levels deep in one call follows so naturally that it survived until the
data hit it. It does not survive the data. Of 394 consecutive
`map_query → map_query` pairs, only **19.3%** carry a term from the
previous query's *result*; **50% have no `kind` filter on either side**.
The actual pairs are `*col* → *grid* → *lane*`, `*status* → *toolbar*`,
`*park* → *region* → *derived*`. Those are **vocabulary searches** — not
knowing what a thing is called and trying synonyms. A transitive expander
would have elaborated a graph nobody was walking.

(The term-carry test is a proxy and could undercount, since a concept can
be carried without a literal token; treat 19.3% as a floor. The 50%
kind-less figure is direct and does not depend on the proxy.)

## The design

### Intra-file call edges

One edge list per file: `(caller, callee, line)` for calls to functions
declared in the same file. Two sources, very different costs:

1. **`self:foo()` — already extracted, currently discarded.** Removing the
   skip at `map_extract.py:545` and routing those edges to the new list is
   nearly free.
2. **Bare `foo(...)` — needs a new pass**, but a small one: match
   `\b(name)\s*\(` over already-masked code for names in the known
   private-function set, attributed with the existing `caller_at(line)`.

The edge list is one thing; it should be *rendered* twice, because the
forward and reverse questions are both asked and neither should need a
query-time inversion:

- **Forward, at the site** — on the `@fn` row, where the reader already
  is, so scanning the function inventory gives the graph shape for free:

      @fn rebuildPipeline(seed)  @ 4801-4890
          -> sortByPPQ:4812  dirtyChan:4830,4841  renderUnion:4877

- **Reverse, as an index** — a `# Calls (intra-file)` section, one row per
  callee with callers grouped, reusing `render_caller_groups` so it parses
  like every other row:

      @call sortByPPQ  @ rebuildPipeline:4812 flushParked:1450

The rejected alternative is extending `@use` with a `local` kind. It is
the least new machinery and it is wrong: `usedby` scans every map for
callers of a symbol, so every internal helper call would pollute
cross-module caller queries unless the kind were filtered at every call
site. The direction differs, so the row should differ.

**Both directions have to reach `map_query`** (2026-08-01). The section
above describes two renderings and says nothing about the querier, which
reads as though the file were the surface. It isn't. `map_query`
reconstructs every structural result from the `@fn`/`@api` head
(`server.py:566`) and silently drops any line matching neither `_DECL`
nor `_ANN`, so a `->` continuation row would sit in the corpus and never
appear in an answer. That is the diagnosed failure over again: the agent
arrives through the querier, and a rendering it cannot see buys nothing.
So each direction gets a query surface — a kind over the `@call` rows,
and the forward tail carried onto structural results.

**Spec maps are out of scope** (2026-08-01). `map/specs/*.map` render
through their own path, and spec sources are flat: helpers called from
cases, not a graph anyone traces. The edges are for module maps.

**A bare `@call` callee belongs to its file** (2026-08-01). `usedby` filters
a row's target module through `_canon_target`, which reads the receiver out
of the spelling — right for `tm:byUuid`, and empty for the bare names that
are most of the intra index, where it hands back the callee's own name as
its module. So `query='centsToRaw'` finds five callers and
`query='centsToRaw' module='trackerManager'` finds none: the narrowing that
should have been free drops the very half the query was for, and the
both-empty line asserts both indexes were searched, so the wrong answer
arrives with a warrant. A bare callee needs no resolution — the extractor
spells a method qualified and a private function bare, so a bare row is by
construction a call on a function of the file the row lives in, and its
module is the map's stem. Deliberately not extended to the *name*
(`t_fn = callee`, which would let `query='tm:centsToRaw'` reach a private
`centsToRaw`): two maps declare a bare and a qualified name that collide —
`trackerManager` has `flush` and `tm:flush`, `util` has `print` and
`util.print` — so buying that spelling would cost a conflation of two
genuinely different functions.

**The oracle is the spec** (2026-08-01). The repo has no Python test
framework and this phase does not add one. Each item's evidence is the
phase-1 gate — a regen diff that must be purely additive, with the new
rows hand-audited on a few modules — and phase 3's `luac` diff is the
check with a direction to it. A fixture suite written against our own
parser would pin what the parser does, which is what the corpus diff
already shows; it could not tell us the parser is right.

**What the corpus actually holds** (2026-08-01). Both counts above were
wrong, in opposite directions. `self:foo()` is the rare spelling (138
sites); the module's own self-name — `tm:foo()` inside
`trackerManager.lua` — is dropped by the same skip and is 1182 more. But
880 of that 1320 are `function tm:foo(` *declaration* heads: `CALL_RE`
matches the declaration and the intra skip has been quietly eating it,
so the pass needs the declaration-prefix guard `extract_fields` already
carries. Real edges: 418 sites, 171 rows, 38 module maps — small enough
to read, but only because the item carries a filter this section didn't
know it needed.

**The callee is keyed by its declaration head** (2026-08-01) — `@call
tm:byUuid` for a method, `@call util.print` for a namespace dotfn, bare
`@call sortByPPQ` for a private fn. The bare name sketched above
collides: seven modules give one name to both a private fn and a public
method (`trackerManager` does it eight times, `tm:addEvent` over
`addEvent`), so a bare key merges two functions into one row the moment
the bare-call pass lands. Keying by the head splits them by receiver
form — a qualified site is the table member, a bare site the private fn
— and buys the invariant that every `@call` target is a row in the same
map. Callers stay bare names either way: `render_caller_groups`
partitions sites on `:`, so `tm:freezeRegion:1765` would misparse.

**A callee the map doesn't carry is dropped** (2026-08-01). `DAG.lua`'s
indented `function ctx:…` members are deliberately uncaptured, so its 12
`self:trackKeyOf()`-style sites resolve to nothing and emit nothing.
Phase 3's oracle will report them as a disagreement; this is why.

**A caller the map doesn't carry mis-attributes** (2026-08-01, from the
hand-audit). The sibling case, and the worse one, because it emits.
`frontierTails` (`trackerManager.lua:3940`) wraps its parameter list onto
a second line and `LOCAL_FN_RE` wants the closing paren on the
declaration line, so the function is never captured; no span contains its
body, and `caller_at` returns None for every site inside it. Those sites
still render — as bare line numbers, which is also how genuine file-scope
code renders. So "top-level" in the map's vocabulary currently means
either *at file scope* or *inside a declaration the extractor could not
parse*, and nothing distinguishes them. This predates `@call` and is
shared by `@use`, `@field` and `@emits` (`map/trackerManager.map` already
carried bare `3954,3971,3972…` from that same body), so it is not a
regression — but it is a second class phase 3's oracle will report, and
it is the one that bites the forward-tail item: a continuation row has no
declaration row to hang under when the caller was never captured.

**The bare pattern needs a lookbehind** (2026-08-01). Written above as
`\b(name)\s*\(`, which is wrong: `\b` matches after `.` and `:`, so
`tm:rawIndexFor(` satisfies it too and emits a second edge keyed
`rawIndexFor` for a site already keyed `tm:rawIndexFor` — the
private-fn/method distinction the decl-head keying bought, undone by the
pass it was bought for. `(?<![.:\w])`.

**The bare half is seven times the qualified one** (2026-08-01,
measured). 2833 sites, 1150 callee keys, 1169 rows, 53 modules, against
item 1's 418 / 171 / 38 — +7.7% on the 15,214-line module-map corpus and
+14.8% on `trackerManager.map`. So in the big maps the reverse index is a
section you scroll past rather than one you notice. Accepted: it is
additive line-wise, it sits low in the file, and the alternative is not
having the index. But a design about read cost should say the number out
loud rather than meet it later.

**Those numbers were each a step off** (2026-08-01, landed). 2833 is the
pre-dedupe *match* count, and 31 of the matches are one helper called
twice on one line, which `call_seen` folds — so the pass emits **2802
edges** and **1168 rows**. Nor is the pass touching 53 files the corpus
having 53 sections: three of item 1's 38 sectioned modules (`groups`,
`samplePage`, `sampleView`) take no bare site at all, so 18 modules gain
the section and the total lands on **56**. Read cost is +7.9%; the
+14.8% on `trackerManager.map` was exact. Both slips are the same one —
a count taken one step upstream of the thing it was quoted as, matches
before dedupe and files touched before sections gained. Worth naming
because the reflex when a predicted count misses by one is to call it
rounding, and neither of these was.

**Shadowing is a rounding error** (2026-08-01, measured). Four nested
`local <name>` shadows of a module-level helper exist corpus-wide, and
two produce a false edge — `midiManager:625 idOf`, `trackerManager:2010
snapshot`, 0.07% of sites. The measure looks only at `local`
declarations, leaving nested-closure parameters and `for` variables
unchecked, so phase 3's oracle keeps its job; but the guess from house
style holds, and the cheap pass is not on trial.

**A by-name binding is not a call, and stays out** (2026-08-01). 100 of
1250 private fns have no call site at all — they are reached by
reference: command tables (`arrangeDive = diveSelected`), namespace
export tables (`chrome` returning `row = row`), callback arguments
(`allocStream(…, audioValueCompare, …)`). For those the reverse index
answers "nobody calls this" where the honest answer names the entry point
that explains why the helper exists, which is worse than silence. Still
not folded in: phase 3's oracle counts `CALL`, a by-name reference is
`GETUPVAL` without one, and mixing them fills the disagreement rate with
noise — blunting the one check that has a direction to it. Own row kind,
own item.

**Bare line numbers: three classes, not two** (2026-08-01, measured). The
note above splits them into file scope and unparsed declaration. The
commonest is neither: 83 of the 204 unattributed sites sit at function
depth ≥ 1 inside an anonymous closure that has no name to attribute to —
a `tm:subscribe('postflush', function() … persist() … end)` body
(`groupManager:591`), a table-value function (`fs.fileOps.move`,
`configManager`'s `savers.track`). Naming those wants vocabulary the map
hasn't got. The unparsed-declaration class is meanwhile smaller and
sharper than `frontierTails` suggested: nine file-scope `function foo(`
assignments to a `local` forward-decl, missed only because
`NESTED_FN_RE` requires indentation while the `do function foo() … end
end` spelling of the same idiom is captured. None of the nine is a
global.

**The forward direction is a query, not a row** (2026-08-01). The section
above renders the edges twice — forward on the `@fn` row, reverse as the
`@call` index — on the principle that neither question should need a
query-time inversion. Measured, the forward *rendering* costs 1039
continuation rows across 54 modules, half the declaration rows in those
files, +6.3% on the corpus; and it buys nothing, because a site list
(`sortByPPQ:4812`) points *inside the function the reader is already in*.
What collapses the walk is the callee's **declaration**, and only the
querier can supply it. The keying of the intra index by declaration head
makes callee → declaration a total function within one map (1339 of
1339), and the self-name registry extends it across maps for 2429 of the
3525 caller-attributed cross sites — the remaining 1090 being `ImGui.*`
and other externals with no map at all, which is an answer and not a
failure. So no continuation row is emitted, and `uses` reads the caller
field of rows the corpus already carries. Direct `.map` reads are ~18% of
map consultation (245 read-ish calls against 1129 `map_query`), so the
file-side rendering had a constituency; it is not enough to buy a
rendering the querier now subsumes.

**`query` names the subject, in both directions** (2026-08-01). The
proposal that died first was a new `calls` kind beside `uses`: same
relation, same direction, differing only in whether the subject was the
file or the function — with `query` flipping between subject and object
filter. Two kinds whose difference is which slot the query fills is §
Vocabulary's discovery failure arriving in the tool's own surface. The
rule that replaces it: `query` names the subject and `module` says which
module the subject lives in, so `uses` takes a function, `usedby` takes a
symbol, and `usedby`'s documented exception — `module` naming the used
target — stops being one. Two readings are paid for it: `uses` with
`query` as a target filter (5 corpus calls) and `usedby` with `query`
naming a module (7 of 101), each becoming a pointer at the right
spelling. The `usedby` pointer must fire *before* the search rather than
on an empty result: `require` edge targets are bare module names, so a
module name falling through to the raw-target regex comes back with the
require rows alone — a partial answer wearing a complete one's clothes.

**A binding is one kind, and the table it sits in is not the map's
business** (2026-08-01). The tempting split is by family: an export table
(`row = row`) declares a public surface, a command table (`arrangeDive =
diveSelected`) names a verb, a callback argument (`table.sort(out,
ciLess)`) hands over a comparator. Each is a different *reason* for the
reference. None of them is a different fact about reachability, which is
what the row records. Nor could a line-oriented pass draw the line if it
wanted to — a return table, a command table and a config table are all `{
key = value }` from where it stands. So one `@bind` kind; and the
discriminator a reader actually wants arrives free in the caller field,
since command and export bindings sit at file scope and render as bare
line numbers while a callback argument renders under the function that
passed it.

**The pass is mostly filter** (2026-08-01, measured on a prototype). A bare
name in value position is far commoner than a call, so the raw pass yields
214 sites of which 60 are noise — and the two sources look nothing alike. A
forward-declaration list is a name list rather than a reference, and
`trackerManager`'s runs to three lines, so the scan has to know that a
`local` statement wraps. A shadow is a different variable wearing the name:
`local add = (mods & ImGui.Mod_Shift) ~= 0` in `gridPane` while `add` is
also a helper, and `editCursor:868` does it with a comment saying so.
Suppressing a name inside its enclosing captured function, from the `local`
that declares it onward, removes exactly the eight shadowed sites and
nothing else. What survives is 151 sites, 122 helpers, 123 rows, 20 modules
— +1.1% on the module corpus, and every one of the 100 never-called
helpers named.

**The shadow filter reaches back into the call pass** (2026-08-01).
Shadowing was measured at 0.07% of call sites and left to phase 3's oracle
on that basis. The mechanism now exists for bindings, where the rate is
sixty times higher, and a filter applied to one pass but not its neighbour
is a distinction no reader of the corpus could account for. So both passes
use it, and `midiManager:625 idOf` and `trackerManager:2010 snapshot` — a
nested `local function` of the same name, each — leave the corpus. It is
the one non-additive change in the phase, and two lines is a diff that can
be audited by eye.

**A call written `f{…}` is in no index at all** (2026-08-01, measured).
`CALL_RE` and the bare pass both require an open paren, and Lua's sugar for
a single table or string argument does not supply one. 98 qualified sites
disappear on that account, and 13 bare ones. The loss falls where the house
idiom is densest: command registration is written `cmgr:registerAll{…}`
throughout, so the wiring the maps are most often asked about is the wiring
they do not carry. The binding pass excludes the spelling rather than
filing those sites as bindings, which leaves them where they already were;
the repair is its own item.

**A return table of privates leaves a module looking private**
(2026-08-01). `chrome` is a chunk module whose last statement is `return {
colour = colour, … }`, so all thirty of its public functions carry `@fn`
rows under `# Private functions` and the map renders no `# Public API`
section; `masterMix` does the same with one. The `@bind` rows will say the
thirty are bound, which is true and is not the same claim as *exported*.
That the querier resolves `chrome.row` today is luck: the key and the
helper share a name. `fs.fileOps.copy = copyFile` is the same idiom with
the luck removed, and it resolves to `(external)`.

**A chunk is what takes deps, not what returns a table** (2026-08-01).
The two modules above were restyled rather than worked around — `chrome`
now declares `function chrome.foo`, `masterMix` assigns
`masterMix.segment` — and `masterMix`'s map promptly lost its `@deps`
line, its `@require` tags and its whole `# Private state` section. The
return shape was `classify`'s only evidence of chunk-hood, and the
restyle removed it; the evidence it wanted sat one line up, in the
`local chrome, ctx = (...).chrome, (...).ctx` that is what instantiation
actually looks like, but `discover_deps` runs only once mode is already
decided. So a `(...)` deref now counts as chunk evidence ahead of
publication shape, and the two rendering decisions that consulted mode
stop doing so: a dot-function on the returned table is public API
whatever the loading shape, and the `:`/`.` in a Public API header comes
from how the members are declared. `library` had been in the same hole
since it was written — `kind='require' module='library'` answered "no
matches" for a file that requires `util` on line 4, and its calls into
`cm` were missing from the uses index entirely, an unregistered dep
dropping its edges. `paramAutomation`, which publishes both spellings,
now renders a `pa.*` section beside its `pa:*` one.

**The prototype's corpus was not the corpus** (2026-08-01). Two
corrections, pulling opposite ways. The sweep missed
`tests/support.lua`, a module map like any other, which exports
`M.repr = repr`: two sites more. Then `chrome`'s restyle took 29 sites
out, because a helper declared public is no longer a private reached by
reference — the pass did not change, the corpus did. What is in the tree
is 124 sites, 96 helpers, 97 rows, 20 modules. Of 1223 private fns, 81
have no call site at all and 78 of those are named by a `@bind`; the
remaining three — `editCursor resizeBy`, `trackerManager makeTailRules`
and `reconcileDerived` — are called with brace sugar, so they wait on
the item above rather than on this one.

**Nine was one spelling of fifteen** (2026-08-01). The note above counts
the unparsed-declaration class as nine `function foo(` fills of a `local`
forward-decl. That is a count of a syntax, and the class is an idiom. The
same declaration is written `foo = function(...)` six more times, in four
files the note does not name — searching for what the gap looked like
rather than for what it was is what hid them. The fix is two regexes, and
they cannot be unified. Indented, `name = function(` is a
table-constructor value: `add = function(evt)` in trackerView's `edit`
table, the whole `registerAll{…}` command table, coordinator's facades.
None of those is a declaration. So column 0 is the criterion for the
assignment spelling, and it is load-bearing.

**The shells took their annotations with them** (2026-08-01, measured).
Eleven forward-decl rows leave the corpus with the fifteen declarations,
and each carried a hand-written inline doc: `prettyEmit`'s `-- forward
decl (mutual recursion with emitTable)`, `refreshStateTrack`'s `-- used
by createSourceTrack/instantiateFxOnScratch (defined late)`. Every one
states in prose a structural fact the extractor could not compute. The
author was annotating around the blind spot. Closing it makes the prose
redundant — the mutual recursion is now two `@call` rows pointing both
ways — and the regeneration deletes it without asking. Here every fact
survived, checked one by one; the point is that nothing in the mechanism
required it to. `map ≡ regen` is an equality, so it cannot distinguish a
row that has become redundant from the only place a fact was written
down. Removals are the half of the generated diff that has to be read.

**The brace is the whole of the sugar here** (2026-08-01, measured). The
note above pairs `f{…}` with `f"…"`, following Lua's grammar. The corpus
does not: no qualified site is written `recv.fn'…'` at all, and the 124
bare ones are `require 'util'`, an edge `REQUIRE_RE` has always owned.
The quote is also much the more expensive spelling to see. `CALL_RE` runs
over comment-stripped but unmasked lines, so widening it to a quote
matches 1013 sites, nearly every one a string literal that happens to
hold a dot — `'arrange.orphanFill'`, `'palette.base.zone0'` — and the
masked lines cannot stand in for them, because `strip_code` blanks the
quotes along with what they delimit. So the passes take `[({]` and stop.
The one `[[…]]` call in the tree (`continuum.lua:7`) is on an
unresolvable receiver and drops anyway.

**`registerAll{…}` was missing twice over, and the paren was the smaller
reason** (2026-08-01, measured). The brace item was motivated by command
registration: the idiom is written `cmgr:registerAll{…}` throughout, so
the wiring most often asked about was the wiring the maps did not carry.
Teaching the passes the brace does not deliver it. Those 13 sites drop a
step later, at alias resolution, because a scope handle is a plain local
— `local trackerScope = cmgr:scope('tracker')` — and the alias table is
built from imports, constructs and chunk deps. The spec maps get the same
calls right, `cmgr` there being a `util.instantiate` result. Behind the 13
sits a larger population: 2760 qualified sites drop for an unresolved
receiver, and most of that is correct — `reaper` 607, `math` 583, `table`
212, and the parameters and locals. But 147 are `ec`, which `trackerView`
forward-declares at file scope and fills 3700 lines later with
`util.instantiate('editCursor', …)`. That is the forward-decl idiom the
declaration pass was taught last item, arriving in the alias table; it is
its own item, and it is the bigger one.

**The brace sites arrive without callers** (2026-08-01, measured). Both
passes take `[({]` now, and the three helpers the corpus said nothing
reached — `editCursor resizeBy`, `trackerManager makeTailRules` and
`reconcileDerived` — gain call sites. That closes the thread: 84 private
functions had no call site at all, 81 do now, and every one of the 81 is
named by a `@bind`. What the new edges do not carry is attribution.
`resizeBy` renders `@ 754,755` — bare line numbers — because both sites
are `resizeBy{…}` inside a table of anonymous closures, and a closure has
no declaration for `caller_at` to name. The spelling and the idiom
co-occur, a table of one-line closures being exactly where dropping the
parens pays, so the sites this item adds are systematically the least
well labelled of any. That follows from a decision already taken rather
than being a gap in it: column 0 is what separates a declaration from a
table-constructor value, and `growNote = function(p) resizeBy{…} end` is
the latter by construction.

**The alias table was blind in two places, not one** (2026-08-01,
landed). The item was opened on the forward-decl fill the note above
names — `local ec, clipboard, ctx` at `trackerView:262`, filled 3700
lines later — and the search for it turned up a second idiom sharing its
cause. The declaration scan saw only a column-0 `local X = <init>`
complete on one line, so it missed an instance bound inside a function as
surely as one bound in two steps. `continuum.lua` wires the entire stack
from inside `Main()`, and `map/continuum.map` — the wiring file's map —
carried five outbound rows, not one of which reached a manager it builds.
The fills are worth 205 sites and the function-scope instances 38, and
each is one filter widened: an assignment anywhere to a name an init-less
column-0 `local` declares, and a `local` at any indent whose init is
`util.instantiate`. Landed as +102 / −2 lines over five maps — 20
`@construct` rows, 78 `@use` rows, 243 sites — the two removals being the
forward-decl shells the construct rows replace.

**A wrong alias does not drop, it lies** (2026-08-01). The 13
`local trackerScope = cmgr:scope('tracker')` handles stayed out, and the
reason generalises well past them. Widening to "a local whose init is a
call on a resolved alias" would also match `local ps = painter.new(ctx,
chrome, {}, 'arrange')` in `arrangeRender`, where `ps` is *pextStore*'s
self-name: the extractor emits receivers verbatim and the querier
re-resolves them by name, so those 43 painter calls would enter the
corpus as cross-module edges to pextStore. A dropped site is a known gap;
a mis-resolved one is a confident wrong answer, and nothing downstream
can tell the two apart. The same argument kills the blunter shortcut of
emitting any site whose receiver happens to be a corpus self-name — 360
sites, of which some 52 are false: the 43 `ps`, seven `DAG.ctx` naming a
local `{ userGraph = … }` table, two `wiringManager.ctx` naming a
`DAG.compile` result. The handles carry two smaller strikes besides.
`trackerScope` is nobody's `self=` name, so the row would read
`trackerScope:registerAll` and resolve to nothing; and the callee is
absent from every map anyway, `function s:registerAll` being declared
indented inside `newScope` (`commandManager.lua:96`), where an indented
`function X:y` with `X ≠ return_target` is deliberately uncaptured.

**The `ec:` sites left standing** (2026-08-01). `gridPane` calls `ec:` 24
times and `trackerRender` twice, all genuinely editCursor, all bound by
`local ec = tv:ec()` inside a function. Only the dangerous rule above
reaches them, so they stay dropped — true edges the corpus does not
carry. § Mechanism: park the rewrite records what phase 3's oracle could
and could not say about them.

### Vocabulary — unsettled

The 197 kind-less consecutive `map_query` pairs say the agent frequently
cannot name what it is looking for. That is a *discovery* failure and it
was on nobody's list before the corpus produced it. Candidate shapes:
synonym/alias support, fuzzy matching, or returning near-misses instead of
nothing. It wants its own look before anything is built.

Relatedly and more cheaply: `map_query` comes back empty on 207 of its
1,135 calls, and cannot distinguish *no such thing* from *not indexed*.
The notes below measure that population. The three-way split this
paragraph first proposed, and the worked example it was built on, did not
survive the measurement.

**The 380 was navigation-wide, and `map_query`'s own rate is 207 of
1,135** (2026-08-02, measured). § What the corpus says counts 380 empty
*navigation* calls, and `NAV` spans reads, searches and shell greps
besides map calls. The survey's empty detector compounds it: it matches
`no matches found`, where the server emits `(no matches for …)`, so
`map_query`'s own empties were largely invisible to the instrument that
produced the figure. Re-measured over the transcript archive with a
predicate matching what the server actually returns, the rate is 207 of
1,135.

**The three-way split names a population of zero** (2026-08-02,
measured). Of the 207, 147 carry filters that are every one of them
valid, 57 trip the glob-habit note the server already appends, 3 name a
kind outside the vocabulary, one is invalid regex predating the guard —
and not one passes a `module=` matching no map. The worked example that
opened this section, `module=` matched 0 of 66 modules, therefore
describes nothing that happened. What remains is the single distinction
an index cannot draw about itself: whether a thing is absent from the
corpus or absent from the code.

**A caveat is worth having only where it is usually silent** (2026-08-02,
measured). `usedby` accounts for 48 of the empties, and its early return
asserts that both indexes were searched while dropping the
incomplete-recall note every answer with content carries. The tempting
repair is to move that note ahead of the return. The tempting refinement
is to fire it when the queried symbol is declared somewhere, which fires
on 40 of the 48 and is a blanket note wearing a condition. The trigger
that separates is whether the source holds call sites the corpus does
not: 10 of the 34 distinct symbols, against 24 for which *no callers* is
true and also complete. So the drops are tagged in the corpus rather than
disclaimed at query time, and the caveat's silence becomes readable.

**The drop is tagged where it is made and judged where the corpus is
visible** (2026-08-02, landed). Two filters were measured for what a
`@drop` row should hold. The callee-based one keeps only a drop whose
callee name heads a declaration somewhere in the corpus, and it is much
the smaller — 141 rows against 373. It was rejected because it makes one
file's map depend on another file's declaration list: 86 of its 141 rows
hang on a name declared in exactly one other module, while the post-edit
hook regenerates by mtime, so an edit that moves or renames that
declaration leaves the dependent map wrong and silent until some
unrelated commit fails the full check. It would also mean running the
extractor over one file no longer produces what the corpus regen
produces. The filter that landed is receiver-based and file-local: every
unresolved receiver drops a row, bar the Lua stdlib tables and
`reaper`/`gfx`. The corpus-wide judgement moves to query time, where the
corpus-wide view already lives — and there the receiver *is* resolved
speculatively through the self-name registry, the guess § A wrong alias
does not drop, it lies refuses to make in the extractor. The asymmetry is
the heading: in the corpus a wrong alias is a confident wrong answer
nothing downstream can detect, while under a heading that says the
receiver is unproven it is a candidate that did not pan out.

**An empty result now lists the domain it searched** (2026-08-02, landed).
Replaying all 1,148 archived calls against today's server puts the
still-unexplained empties at 91, down from the 147 above — the corpus
itself improved in between. The replay only reads that way once the 469
calls that now fail `re.compile` are set aside: they are pre-regex
vocabulary glob habits (`*fx*`) the server already answers by naming the
fix, so counting them charges a vocabulary change to the mechanism as a
defect. Of the 678 that remain, 587 have content and 91 are empty: 69
generic scans, 33 of them carrying a `module=`, then 9 `usedby`, 6 whose
`module=` matched no map, 5 field and 2 `uses` naming no declaration. The
figure is harness-sensitive rather than tree-sensitive — an earlier run of
the same replay reported 86, while replaying against the corpus as it
stood before that run's own last commit still gives 91, so the difference
lives in how the replay counts and a bare total is not a reproducible
control.

The answer reports what the scan walked rather than guessing at near
misses, and it is proportional to how far the caller narrowed: `kind` and
`module` together list that kind's names, `module` alone gives the kind
histogram and invites a `kind=`, and with neither the answer states the
scope it scanned. That avoids both a tuned threshold and any ranking, and
the histogram pays for itself — one real empty was `kind='fn',
module='curveEditor'`, and curveEditor holds `state:8 require:3 api:1`,
no `fn` at all.

**The phase after this one was vocabulary, and it was not built**
(2026-08-02, decided). The section opens on three candidate shapes and
two of them are now ruled out by decisions taken since. Fuzzy matching
is a tuned threshold with a ranking, which the paragraph above
deliberately avoided; synonyms are a curated table of the corpus's own
vocabulary, a second copy that goes stale unwatched, which is the ground
on which the callee-based `@drop` filter was rejected. The third,
near-misses, is the shape phase 4 delivered in its cheapest form — an
empty answer that hands back the vocabulary it scanned. What is left is
an argument by analogy and not a measurement, so the question is
demoted rather than closed: it stays in § Open questions, alongside
early-return guards and the subagent numbers, as a look nobody has
taken.

The inventory is bare names because rows are roughly ten times the cost
and the modules that actually appear in the empty population are the three
largest in the corpus: `midiManager`'s 53 `fn` heads are 660 characters as
names and unprintable as rows. Annotation kinds are counted and never
listed — `invariant`, `contract` and their kin are prose bodies, and 69
contracts is not a vocabulary. The 2,500-character budget on a listing was
measured rather than chosen: the largest module listing is under 2,600,
while the six longest overall are spec `case` lists whose heads are
sentences (`am_spec`, 68 cases, 4,840 characters). The cut therefore lands
on prose and leaves every module listing whole.

## Mechanism: park the rewrite

Nothing above needs tree-sitter. The winning change is small and additive
to the existing extractor, which argues against the ambitious option on
its own terms — the AST rewrite was justified by accuracy, and accuracy is
the thing the corpus says is not costing anything.

`luac` keeps a narrower role, and a good one. A module-level helper called
from a method is, in bytecode, exactly `GETUPVAL` followed by `CALL`, so
`luac -p -l -l` yields the same intra-file call graph with shadowing and
aliasing already resolved by the compiler. That makes it an **oracle**,
not a producer: build the cheap regex version, diff its edges against
luac's across all 66 modules, and upgrade the mechanism only if the
disagreement rate turns out to matter. Two independent derivations of one
fact is a directional check; a spec written against our own parser is not.

(`luac -l` without `-p` writes `luac.out`. Its listing format is
undocumented and version-coupled, which is tolerable for a hand-run oracle
and would not be for a shipped dependency. Instruction order is not source
order — the compiler reorders, so line numbers within a prototype are not
monotonic.)

**Migration discipline.** 66 maps and `map_query` depend on the format.
Any change to how the extractor parses should hold the emitted `.map`
byte-identical first, diff all 66, and treat every non-zero diff as either
a new bug or a provable improvement audited one at a time. New sections
land only after that gate. Otherwise a fix and a regression are
indistinguishable.

**The gate needed `sha=` out of the header first** (2026-08-01). The
discipline above quietly assumes byte-identity is *reachable* on a clean
tree. It wasn't. The header carried `sha=`, the source's last-commit short
hash from `git log -1` at generation time — and maps regenerate on edit,
which is always before the commit exists, so a committed map's sha was one
commit stale by construction. A fresh regen disagreed on 125 of 317 maps
on that field alone, with zero content drift anywhere in the corpus. 39%
wrong was the steady state, not a backlog.

That is fatal to this section specifically: a gate reporting 125
differences on a clean tree cannot tell a regression from a fix, nor
either from a commit having happened — the exact confusion the paragraph
above exists to prevent. Nothing read the field (`map_extract` wrote it;
`server.py`'s header regex required it only to discard the capture), so it
was dropped and the corpus regenerated: header lines only, verified zero
non-`sha` differences. Full regen fell from 12s to 1.7s, the 317 `git log`
subprocesses having been most of the cost.

The trap worth naming is the tempting repair — keep the field, but make it
a content hash of the source rather than a git sha. Self-verifying, and it
makes a staleness check cheap enough to skip parsing entirely. It fails
here, and backwards: when the *extractor* changes, every source hash is
unchanged, so it would pronounce the corpus current at precisely the
moment every map in it is stale. Staleness in a derived corpus is a
property of the generator, not of the source.

**The gate's two modes came out asymmetric** (2026-08-01).
`tools/map_regen.py` now owns the source set — `*.lua` and `tests/*.lua`
→ `map/`, `tests/specs/*.lua` → `map/specs/` — and drives the extractor
in-process across all 318 in 1.6s. Where the design above was silent, two
choices, both falling out of one distinction: `--check` asks whether the
corpus can be trusted, `--write` makes it so. So an orphan — a `.map`
whose source is gone — fails `--check` and not `--write`, because a hook
regenerating a single edited file has no business failing over a stale map
nobody touched. And `--write` writes only the maps whose content actually
changed, so mtimes stay put.

That second one quietly settles part of a decision still ahead of it. The
hooks were to run something like `--stale-only` on two grounds, speed and
not rewriting 318 files per edit; the second is now true by construction,
so `--stale-only` has to earn itself on the 1.6s alone.

**It earned itself, on the 1.6s** (2026-08-01). Measured rather than argued:
a blanket `--write` over a clean corpus is 1.55s, an mtime scan of all 318
pairs is 25ms including interpreter start, and one map renders in about 5ms.
Fifty-fold on the path that fires after every edit, for a six-line filter.
So both hooks run `--write --stale-only`, and the third copy of the
source-set mapping — 400 characters of inline `jq` and `bash` in
`settings.json`, dispatching on path shape, and the copy that was wrong —
is gone. Note what made the collapse possible: once staleness is the
trigger, the tool that reports its file path and the tool that cannot need
the same command, so the two hook entries became one on the matcher the
luacheck hook already used.

The filter is mtime and the write test is content, and they disagree in one
direction: a source edited without changing its map stays mtime-stale and
re-renders every run. Left that way deliberately. The repair — touch the map
when the content is unchanged — would spend the property `--write` was given
in the first place, that mtimes stay put, to save 5ms.

`--check --stale-only` is refused rather than supported. It would report
"all current" having declined to look at exactly the files likeliest to have
drifted, and a gate whose cheap mode lies is worse than a gate with one mode.

**The oracle's unit is the call site, not the edge** (2026-08-01,
settled). The section above says "the same intra-file call graph", and §
Intra-file call edges promises the oracle will report the 26 `ec:` sites
the corpus drops. Only the first is deliverable. luac certifies that a
call happened and how it was spelled; it cannot certify a target module,
because `ec:row()` compiles to a call on a local whether `ec` is
editCursor or anything else. A cross-module check could therefore report
omissions and never correctness — half a check, and the half that does
not bear on whether the cheap pass gets upgraded. So the diff is
intra-file `@call` only. Those `ec:` sites stay dropped and now stay
unreported: a known gap with no instrument pointed at it, worth saying
plainly because the earlier note reads as though one were coming.

**The phase's gate cannot fail, so it needs a control** (2026-08-01,
settled). "The oracle is the spec" gave each phase-2 item the
regeneration diff as its evidence. This phase writes no maps, so that
gate passes trivially for every item in it — a probe that cannot hit,
reading exactly like a clean run. And the failure it would hide is the
phase's own: a listing parser that silently stops matching reports zero
luac-side calls, which is to say zero disagreements, which is the answer
the phase most wants to hear. So each item carries a positive control
instead — a hand-counted function whose sites the tool must reproduce —
and the discipline changes here deliberately rather than lapsing.

**What a control covers is a fact about how it was broken** (2026-08-02,
measured). The note above specifies the instrument and leaves its reach
unstated, as though a hand-counted table were sound in proportion to its
size. It is not: teeth are directional, and a green run is one undirected
bit. Item 1's table pins `groups.lua` whole and five named sites, thirty-one
records; broken in five directions it notices four — the singular `1
instruction` header, the `(for state)` locals row, a dropped constant-key
collapse, and a row read and then silently discarded. The fifth it misses.
Widening `CALL`'s write range to the top of the frame, the hazard named as
likeliest to misreport ordinary sites as `callresult`, leaves all eight kind
counts identical and changes twenty-two record names; neither the control nor
the corpus distribution moves at all. The defect the phase most feared is the
one with no instrument pointed at it. One line closes the gap:
`chrome.lua:337`, `seg.visible()` on a `for` variable, which the locals walk
resolves only because 5.4 emits `TFORCALL` after the loop body — and which a
widened `CALL` therefore steals.

**The rate is zero, and the classes are the finding** (2026-08-02,
measured). `tools/map_diff.py` joins both corpora on the enclosing
declaration's source span and classifies every intra-file call site. Of
the 3026 `@call` sites the extractor attributes to a caller, 3026 have a
bytecode call at the same span, spelling and line. Nothing is map-only —
no edge with no call behind it. And nothing in scope is luac-only — no
call the extractor should have caught and didn't, where *in scope* means
a callee that is a declared name bound in the main chunk. Cross-module
`@use` rows are excluded for the reason the note above gives, and `@bind`
rows because a by-name reference is a `GETUPVAL` with no `CALL` after it.
So the regex pass is not upgraded: the accuracy case for the AST rewrite
is now answered by a measurement rather than by a guess about house style.

**Agreement on a spelling is not agreement on identity**, which is what
makes the zero worth anything. `midiManager` declares `idOf` at file
scope and again at 624 inside `mm:load`. An edge to the inner one would
carry the same caller span, the same name and the same line as an edge to
the outer, so a diff on that triple alone scores the corpus's central
hazard as agreement. Each agreement is therefore certified by walking the
callee's upvalue chain to the prototype it is a local of: 2896 bind in
the main chunk, 130 are a method's own `self` — identity by construction,
since the enclosing `@api <recv>:<name>` row names that receiver — and
none binds to a nested declaration wearing the same name. The corpus
holds exactly two such shadows, `idOf` and `trackerManager`'s `snapshot`
(declared 1174-1178, redeclared at 2000 inside `tm:tileLength`), and the
extractor suppresses both.

**One defect, and it is not a shadow.** `groups.lua:38` calls `resolve`,
which line 25 binds as `local resolve = groups.resolve`. The map spells
callees by declaration head, so the alias site produces no edge at all,
and `groups.resolve` reads as having one caller fewer than it has. One
site corpus-wide. It is reported as its own class rather than folded into
out-of-scope, because the two are not the same finding: out of scope is a
call the corpus never claimed, and this is a call it claims and does not
carry.

**The 250 unattributed sites are the corpus's real gap.** They are `@call`
rows whose site carries no caller name, because no captured declaration
encloses the line; the edge survives and the "who calls this" answer does
not. The run names them by the luac prototype whose span owns each line —
mostly one-line `function(...)` values in table constructors, plus 69 in
the main chunk itself. That list is the declarations the extractor never
captured, and it is actionable in a way an error rate of zero is not.

**What a control covers is, again, a fact about how it was broken.** The
table pins sixteen hand-derived rows over six modules — `groups.lua`
whole, and six source lines each reaching a trap the others do not.
Broken in six directions it notices six: dropping the closure lift,
dropping the `self:` rewrite, skipping one-line declaration spans,
deleting a `@call` site from a copied map, adding a bogus one, and
forcing every binding to read as file scope. The last of those moves
`idOf` and not `snapshot`. `snapshot` is excluded a step earlier, by luac
spelling it a `local` rather than an upvalue, so the binding walk never
sees it — the local-shadow class rests on `map_oracle`'s kind assignment
and not on anything `map_diff` does, and it is the one direction the
control cannot test. Measured instead of assumed: exactly one local-bound
call in the corpus shares a name with a file-scope declaration, and it is
`snapshot`.

**The `ec:` prediction was unsatisfiable, not merely unmet** (2026-08-02).
§ Intra-file call edges left the 26 `ec:` sites for phase 3's oracle to
report, and phase 3 did not report them. The tempting reading is that the
diff was scoped too narrowly, and that a wider one would deliver them. It
would not: `luac` certifies that a call happened and how it was spelled,
never what module a receiver denotes, and the bytecode for `ec:row(…)` is
a `SELF` on an upvalue that says nothing about editCursor. `@use` rows are
not diffable this way at all, so the oracle is silent on the entire
cross-module surface by construction.

**One rule produces both alias findings, and no safe repair follows**
(2026-08-02). The 26 `ec:` sites and the single `groups.lua:38` site read
as a gap and a defect, but the map spells a callee by its declaration
head, so a name bound to an alias carries no edge — the same rule at
cross-module and at intra-file scale. The repair that suggests itself is
to widen the alias table until it reaches `local ec = tv:ec()`, and
§ Intra-file call edges has already priced it: that rule also matches
`local ps = painter.new(…)` and enters 43 painter calls as edges to
pextStore. A dropped site is a known gap; a mis-resolved one is a
confident wrong answer. So the sites stay out, named here so that a later
reader finds a decision rather than an oversight.

**A held row buys attribution, not an edge** (2026-08-02). Teaching
`map_diff` to read `@held` rows put them through the whole declaration
branch, `ms.heads` included, and `luac-only, in scope` went 0 → 45 — 43 of
them `edit.assign` / `edit.add` / `edit.delete` in trackerView. The callers
were never in doubt: `heads` is the map's *callee* vocabulary, and the
`@call` pass spells no held literal as a callee, so admitting the names
there faults the map for edges it has never claimed. A held row therefore
contributes a span and a `by_name` entry and stops short of `heads`. The
gap underneath is real and newly visible — by the contract in § Intra-file
call edges a `@call` callee "always names a row in the same map", and a
`@held` row now is one — but closing it adds `@call` row heads, which is
what this phase's own evidence check forbids, so it is separate work.
*Reopens* when the `@call` pass learns to spell a held callee; the symptom
to expect first is these same 45 records, parked in `out of scope` until
then.

## Open questions

- Are early-return guards worth surfacing? "This function does nothing
  unless X" is a recurring answer when tracing why something *didn't*
  happen, and it is invisible until the body is read. Untested — it should
  be checked against the corpus, not assumed.
- Do these numbers hold for subagents? They were excluded as bulk readers
  by design; whether their navigation is also chain-shaped is unknown.
- Does the vocabulary problem want synonyms, fuzziness, or better negative
  results? Unknown, and the three have very different costs.
