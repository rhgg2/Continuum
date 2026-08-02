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

- 2026-08-02 **One missed capture, six apparent defects.** `tools/map_extract.py`'s five declaration-head regexes all spell the parameter list `\(([^)]*)\)` and match one line at a time, so `trackerManager`'s `frontierTails` — the corpus's only head whose signature wraps — was absent from the map entirely, and with it every call site nested beneath it: the map attributes a site to its nearest enclosing *captured* declaration, so the five literals inside its body presented as file-scope anonymous functions, a different defect class. A single pre-pass joins a wrapped head onto its own line before any regex sees it, rather than making five regexes tolerant of an unterminated open paren; a Lua parameter list holds no parens of its own, so the first `)` closes it and no depth counting is needed. `classify` and `spec_parse` share the pre-pass and are zero-diff today, which is the point — the failure they would have is a helper silently missing from a map. Exactly one map changed, 42 lines added and 38 removed, and stripping `frontierTails:` from both sides absorbs every removed line: the rest of the diff is bare line-number groups gaining a caller, `@call nearestNote @ 4015,4016,4025,4026` becoming `@call nearestNote @ frontierTails:4015,4016,4025,4026`. The phase control moves by its sized amount — `map_diff.py` reports `unattributed 1361 <- map 240, luac 1121` against 250/1153, and its prototype list drops from 132 rows to 126, the six being `frontierTails`' own span and the five literals that now sit inside it. No new false edge: `map-only 0`, `luac-only, in scope 0` and `luac-only, alias 1` all unchanged, `agreed` rises 3,026 to 3,037, and `--control` still reports its 16 hand-derived rows all agreeing. Every number was predicted by a spike of the same change before implementation and met on the nose. No `.lua` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-02 **An empty answer names the domain it searched, and the control number was not reproducible.** `map_query`'s empty result now carries a second line accumulated during the failed scan rather than re-derived after it, proportional to how far the caller narrowed: `kind` and `module` together list that kind's bare names, `module` alone gives the kind histogram and invites a `kind=`, and with neither the answer states the scope it scanned. `curveEditor` comes back `holds no fn. It holds: state:8 invariant:5 contract:5 shape:5 require:3 reaper:2 deps:1 api:1`, which is the entire answer in one line, and `trackerView`'s histogram replaces an echo of the caller's own arguments. Bare names because a `src:line @kind head` row is roughly ten times the cost and the modules dominating this population are the three largest in the corpus; annotation kinds counted and never listed, because 69 contracts is not a vocabulary; a 2,500-character budget that leaves every module listing whole and cuts only the spec `case` lists whose heads are sentences, `am_spec`'s 68 cases at 4,840 characters being the positive control that it fires at all. The replay over 1,148 archived calls is where the item did not land as briefed: it gives 91 empties, not the 86 the brief made a mandatory control, and the gap is in the instrument rather than the tree — replaying against the corpus as it stood before the previous commit gives 91 unchanged, while the brief's own stated predicate yields 69, its stated split sums to 87, and its three-way table leaves 6 of its 1,135 calls unaccounted. So the design doc records 91 with its composition and the note that a bare total is not a reproducible control. Every substantive claim holds at the larger number: all 69 generic empties carry a second line, and all 33 carrying a `module=` carry an inventory or histogram rather than falling back to the scope sentence. No `.map` churn, suite green at 2,227. (design § Vocabulary — unsettled)
- 2026-08-02 **The drop is tagged where it is made, and judged where the corpus is visible.** `map_extract` emits `# Unresolved receivers` — `@drop <target>  @ <sites>` for every qualified call site whose receiver its file-local alias table cannot resolve, the Lua stdlib tables and `reaper`/`gfx` excepted — and `usedby` answers in three sections instead of two, the third resolving those receivers speculatively through the self-name registry under a heading that says they are candidates rather than edges. `ec:isInRegionMode` went from two spec callers plus a trailing hedge to two spec callers and gridPane's four sites named; `Dropped receivers  (none)` is now the positive statement the hedge could not make. 377 rows over 673 sites across 44 maps, and the diff is purely additive — 421 lines added, zero removed, which is the claim that the rewritten `CALL_RE` loop moved no existing edge — with the directional signal, as before, the check-mode run between the code edit and the write: exactly 44 module maps, no spec map. The sizing measured before implementation was 373 distinct rows over 694 sites. The rows agree exactly, the four extra being chunk splits and the six worst maps landing on their predicted counts; the 21-site gap is the unit rather than the rule, since re-counting raw matches at the emitted sites gives back 694 against the 673 `add_drop` emits after deduping on `(target, line)`. The callee-based filter was rejected ahead of all this: smaller at 141 rows, but 86 of them hang on a name declared in exactly one other module, which an mtime-based regen hook cannot watch go stale, so the corpus-wide judgement moved to query time where the corpus-wide view already is. Alongside, an unknown `kind=` is an error naming the vocabulary rather than `(no matches …)`, which said *no such thing* where the truth was *no such filter*; and the two-way budget split generalised to three, reproducing the old arithmetic over 20,000 random triples. No `.lua` churn, suite green at 2,227. (design § Vocabulary — unsettled)
- 2026-08-02 **The rate is zero, and the binding walk is why that means anything.** `tools/map_diff.py` joins both corpora on the enclosing declaration's span and classifies every intra-file call site: 3,026 attributed `@call` sites, 3,026 agreements, no map-only edge and no in-scope luac-only call across the 64 modules. A triple diff would have reported that same zero while being structurally unable to see the corpus's central hazard — `midiManager` declares `idOf` at file scope and again inside `mm:load`, and an edge to the inner one carries the identical span, name and line. So each agreement is certified by walking the callee's upvalue chain to the prototype it is a local of, on the `instack`/`idx` columns `map_oracle` was already parsing and discarding. 2,896 bind in the main chunk, 130 are a method's own `self`, none binds to a nested declaration; the corpus's two shadows, `idOf` and `trackerManager`'s `snapshot`, are both suppressed. The one defect is an alias rather than a shadow: `groups.lua:38` calls `resolve`, bound at line 25 as `local resolve = groups.resolve`, and the map spells callees by head, so the site carries no edge at all. The 250 unattributed sites are reported by the luac prototype owning each line, which names the declarations the extractor never captured. Six perturbations, six noticed — two only after the harness itself was fixed, a transform that had matched nothing and a probe that could not hit both reading exactly like a clean run. The seventh direction is recorded rather than closed: a local-bound shadow never reaches the binding walk, `snapshot` being excluded a step earlier by luac's kind. So the cheap regex pass is not upgraded. Controls green at 31 and 16 records, no `.map` churn, suite green at 2,227. (design § Mechanism: park the rewrite)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. A function literal held in a named table field takes the field's
   name. Eighty-four of the hundred and eighteen unattributed
   prototypes are this shape, in two spellings that share one rule:
   `deleteSel = function() ... end`, and the `registerAll{...}` command
   form `deleteSel = { function() ... end, 'Delete selection' }`. The
   field key is the name a reader would use — the verb in the command
   table, the method on a facade — so the caller row spells it as
   written. This is where the machinery for attributing a file-scope
   literal gets built, and the two naming items after it sit on top of
   that.
2. The other two named constructs: an assignment through a wrapper, and
   a handler registration. Seven prototypes are
   `local deleteSel = util.atomic('Delete swing', function(tier, name)
   ... end)`, where the name is on the left of the assignment and the
   literal is an argument — a straightforward extension of item 2.
   Eighteen are registrations: `tm:subscribe('rebuild', function() ...
   end)`, `modalHost:registerKind('confirm', ...)`, `ps:watch(...)`.
   Those carry no name at all, only a receiver and a signal string, and
   the decision this queue does not settle is whether a handler is named
   from its signal and how it is spelled so it reads as neither a
   declaration nor a call. Settle that with the sites in view.
3. Sixty-nine sites in the module's own file-scope body, and whether
   they get a caller at all. Fourteen rows of the unattributed list are
   load-time wiring: no enclosing declaration, and no construct holding
   them either, so the choice is a synthetic caller that cannot be
   mistaken for a declaration, or leaving them out. Deciding they stay
   out is a legitimate landing, provided the map says so rather than
   letting them read as an oversight.
4. Re-run the oracle and record what the phase actually bought.
   `map_diff.py`'s unattributed count is this phase's own control: it
   stands at 250 today, and each item above predicts how far it should
   fall, so an item that lands without moving the count by its sized
   amount has not done what it claimed. The closing run states the
   residue and the classes it belongs to, and that finding — written
   into `design/map-navigation.md` § Mechanism: park the rewrite — is
   the programme's last piece of evidence before `/plan-close`.
