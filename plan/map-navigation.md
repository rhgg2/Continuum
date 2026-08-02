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

- 2026-08-02 **The drop is tagged where it is made, and judged where the corpus is visible.** `map_extract` emits `# Unresolved receivers` — `@drop <target>  @ <sites>` for every qualified call site whose receiver its file-local alias table cannot resolve, the Lua stdlib tables and `reaper`/`gfx` excepted — and `usedby` answers in three sections instead of two, the third resolving those receivers speculatively through the self-name registry under a heading that says they are candidates rather than edges. `ec:isInRegionMode` went from two spec callers plus a trailing hedge to two spec callers and gridPane's four sites named; `Dropped receivers  (none)` is now the positive statement the hedge could not make. 377 rows over 673 sites across 44 maps, and the diff is purely additive — 421 lines added, zero removed, which is the claim that the rewritten `CALL_RE` loop moved no existing edge — with the directional signal, as before, the check-mode run between the code edit and the write: exactly 44 module maps, no spec map. The sizing measured before implementation was 373 distinct rows over 694 sites. The rows agree exactly, the four extra being chunk splits and the six worst maps landing on their predicted counts; the 21-site gap is the unit rather than the rule, since re-counting raw matches at the emitted sites gives back 694 against the 673 `add_drop` emits after deduping on `(target, line)`. The callee-based filter was rejected ahead of all this: smaller at 141 rows, but 86 of them hang on a name declared in exactly one other module, which an mtime-based regen hook cannot watch go stale, so the corpus-wide judgement moved to query time where the corpus-wide view already is. Alongside, an unknown `kind=` is an error naming the vocabulary rather than `(no matches …)`, which said *no such thing* where the truth was *no such filter*; and the two-way budget split generalised to three, reproducing the old arithmetic over 20,000 random triples. No `.lua` churn, suite green at 2,227. (design § Vocabulary — unsettled)
- 2026-08-02 **The rate is zero, and the binding walk is why that means anything.** `tools/map_diff.py` joins both corpora on the enclosing declaration's span and classifies every intra-file call site: 3,026 attributed `@call` sites, 3,026 agreements, no map-only edge and no in-scope luac-only call across the 64 modules. A triple diff would have reported that same zero while being structurally unable to see the corpus's central hazard — `midiManager` declares `idOf` at file scope and again inside `mm:load`, and an edge to the inner one carries the identical span, name and line. So each agreement is certified by walking the callee's upvalue chain to the prototype it is a local of, on the `instack`/`idx` columns `map_oracle` was already parsing and discarding. 2,896 bind in the main chunk, 130 are a method's own `self`, none binds to a nested declaration; the corpus's two shadows, `idOf` and `trackerManager`'s `snapshot`, are both suppressed. The one defect is an alias rather than a shadow: `groups.lua:38` calls `resolve`, bound at line 25 as `local resolve = groups.resolve`, and the map spells callees by head, so the site carries no edge at all. The 250 unattributed sites are reported by the luac prototype owning each line, which names the declarations the extractor never captured. Six perturbations, six noticed — two only after the harness itself was fixed, a transform that had matched nothing and a probe that could not hit both reading exactly like a clean run. The seventh direction is recorded rather than closed: a local-bound shadow never reaches the binding walk, `snapshot` being excluded a step earlier by luac's kind. So the cheap regex pass is not upgraded. Controls green at 31 and 16 records, no `.map` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-02 **The parser landed behind its control, and the control caught what the brief had lost.** `tools/map_oracle.py` turns one module's `luac -p -l -l` listing into call records — 64 modules, 3,314 prototypes, 13,055 sites, zero `unknown`, a kind distribution matching the spike's to the record. The hand-counted table was written from the `.lua` and seen to fail 31 of 31 against a stub before any parser existed, which is what made its first real failure legible: `SELF` carries the same 8-bit constant-operand overflow the brief documented for `GETTABUP` alone, 23 sites, and it crashed the parse. The prose had dropped it; the brief's own `method 2451` checksum had pinned it all along, being exactly the corpus's `SELF` count. Layer 1 counts the structures it built rather than the lines it read, a distinction worth nothing until a row is read and then discarded — the one drop path a raising regex cannot cover. Five perturbations, four noticed; the fifth is recorded in the design doc, an over-broad `CALL` range that moves twenty-two names and not one kind count. No `.map` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-01 **The alias table was blind in two places, not one.** The plan item named the forward-decl fill — `local ec, clipboard, ctx` at `trackerView:262`, filled 3700 lines later — and the search for it turned up a second idiom with the same cause: the declaration scan saw only a column-0 `local X = <init>` complete on one line, so an instance bound inside a function was as invisible as one bound in two steps. The second is what fixes `map/continuum.map`, the wiring file's map, which carried five outbound rows and no edge to anything it builds; `Main` now resolves `coord:register` ×5, `coord:setActive` ×10, `cmgr:registerAll` and the rest to their declarations, and `usedby ec:row` goes 9 cross-module sites to 34. The regen gate cannot fail for a no-op, so the directional signal is the check-mode run between the code edit and the write: exactly the five expected maps, no sixth. +102/−2 across them — 20 `@construct` rows, 78 `@use` rows, 243 sites — and the only two removals in the whole diff are the forward-decl shells the construct rows replace. The scope handles stayed out, and the reason generalises past them: the extractor emits receivers verbatim and the querier re-resolves them by name, so the general form of the rule would land `local ps = painter.new(…)` in `arrangeRender` as 43 cross-module edges to pextStore. A wrong alias does not drop, it lies. `gridPane`'s 24 `ec:` sites stay dropped for want of a safe rule, for phase 3's oracle to report. (design § Intra-file call edges)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **An empty result lists the domain it searched.** For the 147 empties
   whose filters are all valid, the tool currently echoes the caller's own
   arguments back, and the next move is a shell grep. Where the filters
   narrow to a module or a kind, list what that domain does hold — the
   `fn` heads in `midiManager`, the `api` heads on `trackerManager` — and
   where they do not narrow, say that rather than printing the corpus. No
   ranking and no nearest-miss scoring: a module's declarations are few
   enough to print in full, and a list is right without a scoring function
   to be wrong about.
