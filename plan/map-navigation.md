# map navigation — plan

> source: `design/map-navigation.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — the regeneration gate** (§ Mechanism: park the rewrite)
   — regenerate every map the extractor emits (the 66 modules, the spec
   and harness maps alongside them) and diff against the committed ones
   in one command; `map_extract.py` is one-file-per-call today. Every
   later phase lands behind it, byte-identical first.  ✓ done
2. **Phase 2 — intra-file call edges** (§ Intra-file call edges) — one
   `(caller, callee, line)` list per file, from the `self:` edges
   currently extracted and discarded plus a new bare-`foo(...)` pass
   over masked code; rendered twice, forward on the `@fn` row and
   rendered as a `# Calls (intra-file)` index, with the forward
   direction served by `uses` rather than by a row.
   ✓ done (2026-08-01, 9 commits)
3. **Phase 3 — the luac oracle** (§ Mechanism: park the rewrite) — diff
   phase 2's intra-file `@call` edges against `luac -p -l -l` across all
   64 modules; the disagreement rate is what decides whether the cheap
   pass gets upgraded, and it answers the shadowing open question.
   ✓ done (2026-08-02, 2 commits)
4. **Phase 4 — negative results that say why** (§ Vocabulary —
   unsettled) — `map_query` comes back empty on 207 of its 1,135 calls
   and cannot say whether a thing is absent from the corpus or absent
   from the code. The receivers the extractor drops get tagged so an
   empty answer can name them, and an empty result lists the domain it
   searched.  ✓ done (2026-08-02, 2 commits)
5. **Phase 5 — the unattributed sites** (§ Mechanism: park the rewrite)
   — the last phase. Phase 3's oracle found 250 `@call` sites whose
   caller cannot be named, because no captured declaration encloses the
   line: the edge survives and the "who calls this" answer does not.
   They are function literals at file scope, where there is nothing to
   inherit a name from, and all but a handful sit in a construct that
   already holds a name — a table field, an assignment target, a signal.
   Give them that name, then re-run the oracle and record the residue.
   ← in flight

Vocabulary — synonyms, fuzziness or near-misses — was phase 5 and is
not being built. Phase 4 gave an empty answer the vocabulary of what it
searched, which is the near-miss candidate in its cheapest form; of the
other two, one is a tuned threshold and one is a curated second copy of
the corpus's own vocabulary, and this programme has ruled against both
shapes elsewhere on the record. That is an argument by analogy rather
than a measurement, which is why it demotes the question rather than
answering it: it goes back to `design/map-navigation.md` § Open
questions to sit with the other two unlooked-at ones.

## Landed  (newest first; prune below ~4)

- 2026-08-02 **Two constructs captured, and a third rule the line number could not express.** `map_extract` now names the wrapper assignment (`local revert = util.atomic('Revert swing', function(name)`, twelve of them) with a declaration row of its own — `@fn` for a bare local, `@api` when the target is the module's own table, which is how `tv:applyTakeProperties` acquired the declaration it has never had — and the handler registration (`tm:subscribe('rebuild', function(takeChanged)`, thirty-five) with a new kind, `@handler tm:rebuild(takeChanged)`, in its own section. Not `@held tm.rebuild`: tm holds no such field, it was handed the literal, and `tm:rebuild` is the spelling the `@use sub tm:rebuild` row already uses for the same object; a registration passing no string literal falls back to `<recv>:<method>`, which keeps the rule total over the construct. Moving the field-key test inside the brace walk, so each rule fires at the literal's own position, is what keeps `facade.publish('sample', { setTrack = function(track) … })` a held row rather than a confidently-wrong handler on facade, and it picks up five more held literals on the way, `env.print` and `io.open` among them. Wrapper names enter `heads`, the map's callee vocabulary — they are spelled bare at their use sites — and bought eleven edges the corpus was missing with `luac-only, in scope` staying 0, which is the check that earns the admission; handler names stay out, for the reason the held item recorded. Unattributed `@call` sites fell 125 → 72: 69 in the main chunk, one computed key at `arrangeView:658`, and two the brief did not foresee. Those two are the finding. Capturing a handler put `map-only` at 2 for the first time in the phase, because `wm:subscribe('wiringChanged', function() wv:rebuild() end)` makes two calls on one line — the subscription in the enclosing scope, `wv:rebuild` inside the handler — and line-granular attribution claimed both; it surfaced only where the registrar is the module itself (`modalHost:registerKind` at 109 and 118) and the false caller therefore became an intra-file `@call` rather than a `@use` the oracle cannot read. No line-granular rule separates those two sites, so a block now carries the column its literal opens at and a site on its first line belongs to it only from that column on; the same defect was already in the corpus under the held rule, `facade.publish` attributing its own publish call to `sample.setTrack`, and this closes it. The `@field` index keeps the defect — `@field w applyTakeProperties @ applyTakeProperties:519` still names a declaration as its own writer — because that reading is pre-existing and general to every `function recv.name(…)` head, so it is separate work. One plumbing hazard was silent rather than loud: `server.py`'s site parser split on the *first* colon, so every handler-attributed site would have vanished from `uses` and `usedby` answers without an error; `map_diff` raises on the same class by construction, and did. First non-additive corpus diff of the phase — 11 `@state` rows dropped, each one a wrapper-assignment line now carrying an `@fn`, all eleven audited — and a triple-level audit over every site row confirms 0 lost against 11 gained. `map_regen --check` clean, `--control` 16 rows agreeing, no `.lua` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-02 **The server matches the held rows, and the battery could not produce one of its own predicted classes.** `map_query` now reads `@held` rows as declarations: `kind='held'` lists them, `uses` names a held function as a subject, and the kind histogram counts them. A held name stays qualified — `_bare_name` keeps the table, since sites spell their caller `editCursor.logPerRow` and the span test joins on that spelling — and held rows enter `_decl_index` wholesale, no guard, because no `@call` row spells a held literal as its callee today and the join therefore never lands on one. Re-confirmed before relying on it: 165 rows over 154 map-and-key pairs, no unqualified name, no key colliding with an `fn` or `api` in the same map, none spelled as a callee anywhere. The evidence is a differential between the spike, unedited and on the same corpus, and the edited tree — 10,397 identical questions each, every stem by every kind plus `uses` on every fn/api/held bare. 3,451 answers differ, but 2,929 of those are the rewritten `_USES_NOTE` printing in every `uses` answer; normalising it leaves 522, in exactly the three predicted classes and no fourth: 318 maps where `kind='held'` was an error and is now an answer, 154 held subjects `uses` answers for (139 reaching something, 15 reaching nothing, trackerView 56 and arrangePage 16 heading the per-map composition), and 50 domain notes gaining a `held` count across exactly the 17 held-bearing maps. Each of the three teeth moves the class it should and leaves the others standing: stripping the qualifier and dropping held from `_decl_index` both take class 2 to zero, dropping it from `_KINDS` takes class 1 to zero. The class the battery could not produce is the one worth recording. Class 4 needs a query matching a held name and an `fn` or `api` at once, and every question the battery generated was anchored and dot-escaped, so the shape chosen to make the two runs comparable excluded the ambiguity that class lives in — in the diff it reads as *did not occur*. A hand probe found it in one call: `uses query='render' module='trackerRender'` gains seven `@held toolbarSegments.render()` groups printing ahead of `@api tr:renderBody`, whose own content is unchanged at `reaches 27`. That same answer loses `tr:renderStatusBar` off the end of the 60-row budget — widening an index converts an addition into a deletion in every budgeted answer that index feeds, and neither the diff nor the answer says so. The anchored-bare symptom the brief priced exists as priced, `query='^render$'` finding no held row while `toolbarSegments.render` does, and the reopen condition is unmet, so the qualifier stays. One sizing correction: trackerRender holds 12 distinct held keys, not the brief's 18, which is its row count. One file edited, `map_regen --check` clean, no `.map` and no `.lua` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-02 **A function literal in a table field takes the name of the table holding it.** `map_extract` captures a `render = function()` literal at file scope -- and the `registerAll{...}` command form `deleteSel = { function() ... end, 'desc' }` -- as a `@held <table>.<field>` row with a span, emitted between `# Private functions` and `# Public API`. 165 literals across 17 maps, every per-module count as sized. The qualifier is the table rather than the bare field key: eleven literals wear the name of a declaration in the same file, ten of them reading as recursion and `trackerView`'s `logPerRow` silently merging two different functions into one caller group. The corpus diff is purely additive -- row heads identical, line multisets per row head identical, nothing lost and nothing relabelled -- with 115 `@call`, 169 `@use` and 249 `@field` site lines gaining a caller where they had carried only a line number. The phase control moves by its sized amount: `map_diff` reports map-side unattributed 240 to 125 and agreed 3,037 to 3,152, its prototype list dropping from 126 rows to 41, and the 165 new spans pull the luac side from 1,121 unattributed to 811 -- so `map-only 0` and `luac-only, in scope 0` are newly non-vacuous rather than newly trivial. Both held, but only after a correction the brief had priced at zero: routing `@held` rows through the whole of `map_diff`'s declaration branch put their names into `ms.heads`, the map's *callee* vocabulary, and reported 45 calls -- 43 of them `edit.assign` / `edit.add` / `edit.delete` in trackerView -- as edges the map had missed. The `@call` pass spells no held literal as a callee, so a held row buys a span and a caller and stops short of `heads`; the gap underneath is real, newly visible, and recorded for the item that closes it. Two of the brief's by-product numbers came out off by small amounts -- field label gains 249 against a predicted 251, prototype rows 41 against 42 -- while every number the mechanism determines was exact, the ten hand-derived qualifier names included. `--control` green at 16 rows, `map_regen --check` clean, no `.lua` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-02 **One missed capture, six apparent defects.** `tools/map_extract.py`'s five declaration-head regexes all spell the parameter list `\(([^)]*)\)` and match one line at a time, so `trackerManager`'s `frontierTails` — the corpus's only head whose signature wraps — was absent from the map entirely, and with it every call site nested beneath it: the map attributes a site to its nearest enclosing *captured* declaration, so the five literals inside its body presented as file-scope anonymous functions, a different defect class. A single pre-pass joins a wrapped head onto its own line before any regex sees it, rather than making five regexes tolerant of an unterminated open paren; a Lua parameter list holds no parens of its own, so the first `)` closes it and no depth counting is needed. `classify` and `spec_parse` share the pre-pass and are zero-diff today, which is the point — the failure they would have is a helper silently missing from a map. Exactly one map changed, 42 lines added and 38 removed, and stripping `frontierTails:` from both sides absorbs every removed line: the rest of the diff is bare line-number groups gaining a caller, `@call nearestNote @ 4015,4016,4025,4026` becoming `@call nearestNote @ frontierTails:4015,4016,4025,4026`. The phase control moves by its sized amount — `map_diff.py` reports `unattributed 1361 <- map 240, luac 1121` against 250/1153, and its prototype list drops from 132 rows to 126, the six being `frontierTails`' own span and the five literals that now sit inside it. No new false edge: `map-only 0`, `luac-only, in scope 0` and `luac-only, alias 1` all unchanged, `agreed` rises 3,026 to 3,037, and `--control` still reports its 16 hand-derived rows all agreeing. Every number was predicted by a spike of the same change before implementation and met on the nose. No `.lua` churn, suite green at 2,227. (design § Mechanism: park the rewrite)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. Sixty-nine sites in the module's own file-scope body, and whether
   they get a caller at all. Fourteen rows of the unattributed list are
   load-time wiring: no enclosing declaration, and no construct holding
   them either, so the choice is a synthetic caller that cannot be
   mistaken for a declaration, or leaving them out. Deciding they stay
   out is a legitimate landing, provided the map says so rather than
   letting them read as an oversight.
3. Re-run the oracle and record what the phase actually bought.
   `map_diff.py`'s unattributed count is this phase's own control: it
   stood at 240 before the naming items, and each item names the
   direction it moves the count and the class of sites it removes —
   the magnitude belongs to the run that lands it, reported with its
   composition. The closing run states the
   residue and the classes it belongs to, and that finding — written
   into `design/map-navigation.md` § Mechanism: park the rewrite — is
   the programme's last piece of evidence before `/plan-close`.
