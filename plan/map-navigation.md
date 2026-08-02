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
   the disagreement rate is what decides whether the cheap
   pass gets upgraded, and it answers the shadowing open question.
   ✓ done (2026-08-02, 2 commits)
4. **Phase 4 — negative results that say why** (§ Vocabulary —
   unsettled) — `map_query` comes back empty on 207 of its 1,135 calls
   and cannot say whether a thing is absent from the corpus or absent
   from the code. The receivers the extractor drops get tagged so an
   empty answer can name them, and an empty result lists the domain it
   searched.  ← in flight
5. **Phase 5 — vocabulary** (§ Vocabulary — unsettled) — synonyms,
   fuzziness or near-misses. Unsettled by design: the phase opens with a
   look, and its answer reopens `design/map-navigation.md` before
   anything is built.

## Landed  (newest first; prune below ~4)

- 2026-08-02 **An empty answer names the domain it searched, and the control number was not reproducible.** `map_query`'s empty result now carries a second line accumulated during the failed scan rather than re-derived after it, proportional to how far the caller narrowed: `kind` and `module` together list that kind's bare names, `module` alone gives the kind histogram and invites a `kind=`, and with neither the answer states the scope it scanned. `curveEditor` comes back `holds no fn. It holds: state:8 invariant:5 contract:5 shape:5 require:3 reaper:2 deps:1 api:1`, which is the entire answer in one line, and `trackerView`'s histogram replaces an echo of the caller's own arguments. Bare names because a `src:line @kind head` row is roughly ten times the cost and the modules dominating this population are the three largest in the corpus; annotation kinds counted and never listed, because 69 contracts is not a vocabulary; a 2,500-character budget that leaves every module listing whole and cuts only the spec `case` lists whose heads are sentences, `am_spec`'s 68 cases at 4,840 characters being the positive control that it fires at all. The replay over 1,148 archived calls is where the item did not land as briefed: it gives 91 empties, not the 86 the brief made a mandatory control, and the gap is in the instrument rather than the tree — replaying against the corpus as it stood before the previous commit gives 91 unchanged, while the brief's own stated predicate yields 69, its stated split sums to 87, and its three-way table leaves 6 of its 1,135 calls unaccounted. So the design doc records 91 with its composition and the note that a bare total is not a reproducible control. Every substantive claim holds at the larger number: all 69 generic empties carry a second line, and all 33 carrying a `module=` carry an inventory or histogram rather than falling back to the scope sentence. No `.map` churn, suite green at 2,227. (design § Vocabulary — unsettled)
- 2026-08-02 **The drop is tagged where it is made, and judged where the corpus is visible.** `map_extract` emits `# Unresolved receivers` — `@drop <target>  @ <sites>` for every qualified call site whose receiver its file-local alias table cannot resolve, the Lua stdlib tables and `reaper`/`gfx` excepted — and `usedby` answers in three sections instead of two, the third resolving those receivers speculatively through the self-name registry under a heading that says they are candidates rather than edges. `ec:isInRegionMode` went from two spec callers plus a trailing hedge to two spec callers and gridPane's four sites named; `Dropped receivers  (none)` is now the positive statement the hedge could not make. 377 rows over 673 sites across 44 maps, and the diff is purely additive — 421 lines added, zero removed, which is the claim that the rewritten `CALL_RE` loop moved no existing edge — with the directional signal, as before, the check-mode run between the code edit and the write: exactly 44 module maps, no spec map. The sizing measured before implementation was 373 distinct rows over 694 sites. The rows agree exactly, the four extra being chunk splits and the six worst maps landing on their predicted counts; the 21-site gap is the unit rather than the rule, since re-counting raw matches at the emitted sites gives back 694 against the 673 `add_drop` emits after deduping on `(target, line)`. The callee-based filter was rejected ahead of all this: smaller at 141 rows, but 86 of them hang on a name declared in exactly one other module, which an mtime-based regen hook cannot watch go stale, so the corpus-wide judgement moved to query time where the corpus-wide view already is. Alongside, an unknown `kind=` is an error naming the vocabulary rather than `(no matches …)`, which said *no such thing* where the truth was *no such filter*; and the two-way budget split generalised to three, reproducing the old arithmetic over 20,000 random triples. No `.lua` churn, suite green at 2,227. (design § Vocabulary — unsettled)
- 2026-08-02 **The rate is zero, and the binding walk is why that means anything.** `tools/map_diff.py` joins both corpora on the enclosing declaration's span and classifies every intra-file call site: 3,026 attributed `@call` sites, 3,026 agreements, no map-only edge and no in-scope luac-only call across the 64 modules. A triple diff would have reported that same zero while being structurally unable to see the corpus's central hazard — `midiManager` declares `idOf` at file scope and again inside `mm:load`, and an edge to the inner one carries the identical span, name and line. So each agreement is certified by walking the callee's upvalue chain to the prototype it is a local of, on the `instack`/`idx` columns `map_oracle` was already parsing and discarding. 2,896 bind in the main chunk, 130 are a method's own `self`, none binds to a nested declaration; the corpus's two shadows, `idOf` and `trackerManager`'s `snapshot`, are both suppressed. The one defect is an alias rather than a shadow: `groups.lua:38` calls `resolve`, bound at line 25 as `local resolve = groups.resolve`, and the map spells callees by head, so the site carries no edge at all. The 250 unattributed sites are reported by the luac prototype owning each line, which names the declarations the extractor never captured. Six perturbations, six noticed — two only after the harness itself was fixed, a transform that had matched nothing and a probe that could not hit both reading exactly like a clean run. The seventh direction is recorded rather than closed: a local-bound shadow never reaches the binding walk, `snapshot` being excluded a step earlier by luac's kind. So the cheap regex pass is not upgraded. Controls green at 31 and 16 records, no `.map` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-02 **The parser landed behind its control, and the control caught what the brief had lost.** `tools/map_oracle.py` turns one module's `luac -p -l -l` listing into call records — 64 modules, 3,314 prototypes, 13,055 sites, zero `unknown`, a kind distribution matching the spike's to the record. The hand-counted table was written from the `.lua` and seen to fail 31 of 31 against a stub before any parser existed, which is what made its first real failure legible: `SELF` carries the same 8-bit constant-operand overflow the brief documented for `GETTABUP` alone, 23 sites, and it crashed the parse. The prose had dropped it; the brief's own `method 2451` checksum had pinned it all along, being exactly the corpus's `SELF` count. Layer 1 counts the structures it built rather than the lines it read, a distinction worth nothing until a row is read and then discarded — the one drop path a raising regex cannot cover. Five perturbations, four noticed; the fifth is recorded in the design doc, an over-broad `CALL` range that moves twenty-two names and not one kind count. No `.map` churn, suite green at 2,227. (design § Mechanism: park the rewrite)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — phase 4's last item is in flight.)
