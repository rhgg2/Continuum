# nested declarations — the helpers the corpus cannot name

> opened: 2026-08-05 · status: measured in a spike against `0acf5e45`;
> the diff is below, unapplied.

## Problem

**1** A `local function` at module scope earns a `@fn` row. One declared
inside another function earns nothing — no row, no span, no doc comment,
and no name for a call site to be attributed to. The corpus holds 284 of
them, spread over 36 of 59 modules: 79 in trackerManager, 45 in DAG, then
a long tail.

**2** The missing rows are not the whole of the cost. `map_diff` puts the
map's `@call` edges against the bytecode, and calls to these helpers land
in its out-of-scope residue — 595 `local` records and 382 `upvalue`
records, some seven hundred edges the compiler sees and the map cannot
name. Beside them sit 216 lines of doc comment written against a nested
helper, which no map carries today.

**3** The tempting reply is that a nested helper is an implementation
detail of the function holding it, and that the map is right to stop at
the module's surface. It does not survive contact with the corpus.
`freezeRegion>covered` carries the comment *"Window membership only,
never rebuildRegionPark's covered()"* — a distinction drawn, in prose,
between two nested helpers wearing one name. Where the source has had to
disambiguate, the index cannot maintain there was nothing to name.

**4** The corpus is also out of step with its sibling. `flow_extract`
derives nested function frames from source of its own accord
(`block_frames`, `local_name`), so the flow viewer draws a frame the map
denies is a function.

## The criterion

**1** A declaration row buys two things, and both have to survive the
change. The first is a place — `src:line`, so that "where does X live"
has an answer. The second is a *name that site rows can spell*: every
`@call`, `@bind`, `@use` and `@field` row attributes its sites to an
enclosing declaration by name, and the querier joins them back by that
name under a span test.

**2** So the question is not whether nested helpers can be found.
`fn_depth` already knows where each one sits, and the guard excluding
them is a single condition. The question is whether, once they are
admitted, every name in a file still names one thing.

## Two traps

### The file-wide sweep

**1** A module-private helper is called with no receiver, so the
qualified pass cannot see it and a bare-name pass sweeps the whole file
for each helper's name. That sweep is sound only because every captured
name is visible everywhere in the file. Lifting the depth guard alone
breaks the premise and keeps the pass: 65 false edges, 8.5% of the new
ones, among them a call at `help.lua:159` to a `cell` belonging to some
other function's scope. An edge the extractor asserts and the compiler
denies is worse than an edge it never had.

**2** The criterion is that a name is swept over the scope it is
reachable from, and no further: the whole file for a module-scope helper,
and for a nested one, from its own line to the end of the declaration
enclosing it. `visible_ranges` computes it, and the count of false edges
goes to zero.

### A bare name stops being a key

**1** Seven names are declared more than once within a single file —
`covered`, `key`, `authored` and `snapshot` in trackerManager, `routeOf`
in DAG, `rowToX` in gridPane, `idOf` in midiManager. Spelled bare, one
`@call covered` row merges the sites of two different functions, and
`map_index.callee_intra_decl`, which joins the callee spelling exactly,
takes whichever declaration it meets first.

**2** This is the trap that settles the spelling. A qualifier is not
decoration on the row; it is what keeps the callee join total. Qualified,
the corpus's 1630 `@call` rows each join to exactly one declaration —
zero ambiguous, zero unresolved.

## The design

**1** A nested helper is spelled `encloser>name`, as `@held` is spelled
for the table holding the literal and `@handler` for the receiver it is
registered on. The precedent is exact: those two are qualified because a
bare field key collides with declarations elsewhere in the same file. `.`
and `:` are taken — table field, method — and `>` reads as containment.

```
  @fn buildConns(ctx)  @ 595-780
    @fn buildConns>nodeTrackKey(id)  @ 600
    @fn buildConns>audioConn(from, fp, to, tp, gain)  @ 601-604
```

**2** Rows indent one level per enclosing declaration, so the nesting is
legible without reading spans off the ends of the lines.

**3** Site rows go on spelling their caller bare — `@ freezeRegion:1887`.
The server resolves a caller by bare name *and* a span test
(`_uses_groups.owner`), a join already written to tolerate two
declarations sharing a name. So the query surface needs no change at all:
`map_index.bare_name` strips the qualifier, and everything downstream of
it — `decl_row`, `flow_extract.decl_id`, the bare-name scan — is
untouched.

**4** Each bare mention resolves to the innermost declaration in scope at
that line, and the row is keyed by that declaration's head. One rule
settles what were three separate questions: which helper a call reaches,
which row its site belongs under, and why the two `covered`s do not
merge.

**5** The bytecode agrees. Against luac: 3959 sites agreed, none map-only,
none in-scope-but-missed. Every new edge is one the compiler also makes.

## What it costs to read

**1** The corpus grows from 17,642 to 18,428 lines, 4.5%. It falls
unevenly: `trackerManager.map` 1398 → 1630, `DAG.map` 501 → 621, and 23
of 59 modules do not move at all.

**2** Of the 284 new rows, 249 sit at depth one, 32 at depth two and 2 at
depth three — `buildCtx>busLive>mark` is the deepest thing the corpus
contains. Three qualifiers is the practical ceiling on the spelling, and
nothing approaches it.

**3** The claim not being made is that the maps stay readable in one
screen. trackerManager's was not one screen before this and is less so
after. What it gains is that the 79 helpers its longest functions are
built out of become addressable, carrying the prose their author wrote
about them.

## Loose ends

Work the diff does not do, in the order it should be done.

**1** `map_diff` still files the 249 nested-binding edges under `FALSE
EDGES` (`map_diff.py:337`). That label was true while the map claimed a
file-scope declaration for them, and is a misnomer now. The upgrade worth
having is not a renamed counter: luac's `binder()` already knows which
prototype a callee is a local of, so the *qualifier itself* can be
checked against the bytecode. The map would then be certified in its
claim about nesting, and not merely in its claim that a call happened.

**2** Doc comments emit at a fixed six-space indent, so at depth two and
below they sit nearly level with the row they belong to.

**3** Annotation attachment wants a look. Fourteen annotations in the
sources sit directly above a nested helper; some now land on it
(`curveEditor:frame>evalAtT`'s contract) and some still do not
(`trimTop>filter`'s). Those that do not are attaching to whatever
captured element follows, which is a misattribution predating this
change.

**4** Prose: the grammar preamble in `map_extract`'s module docstring and
the `map_query` tool description both enumerate how a row is spelled, and
neither knows about `>`.

**5** Unexercised: the MCP server end to end, and `flow_extract` /
`flow_view`. Their join keys were read rather than run. Worth asking once
they are: whether flow can take its nested frames from the corpus instead
of deriving its own.

## The diff

Against `0acf5e45`, 77 insertions and 19 deletions over three files. It
regenerates the corpus cleanly — `map_regen.py` reports all current after
a `--write` — and `map_diff` runs to the figures quoted above. Extract
the block below and `git apply` it, then `tools/map_regen.py --write`,
which is the whole of the corpus change.

```diff
diff --git a/tools/map_diff.py b/tools/map_diff.py
index bdc06b48..638759d7 100644
--- a/tools/map_diff.py
+++ b/tools/map_diff.py
@@ -61,7 +61,7 @@ class Site:
 # Both rows are emitted by map_extract.emit; `@ n` is a one-liner, so its span
 # is (n, n). `@fn`, `@api`, `@held` and `@handler` together are every function
 # the map gives a span to, and so every caller a site row can name.
-DECL_ROW = re.compile(r'^  @(?:fn|api|held|handler) (\S+?)\((.*)\)  @ (\d+)(?:-(\d+))?$')
+DECL_ROW = re.compile(r'^\s+@(?:fn|api|held|handler) (\S+?)\((.*)\)  @ (\d+)(?:-(\d+))?$')
 CALL_ROW = re.compile(r'^  @call (\S+)  @ (.+)$')
 SELF_MARK = re.compile(r'\bself=(\S+)')     # the @module header's marker
 
@@ -78,12 +78,19 @@ class MapSide:
     n_decls: int = 0
 
 
+def unqualify(head: str) -> str:
+    """`buildConns>nodeTrackKey` -> `nodeTrackKey`. The enclosing scope is the
+    map's own disambiguator; luac spells a callee by its name alone, and the
+    qualifier is checked against the binding prototype rather than the name."""
+    return head.rsplit('>', 1)[-1]
+
+
 def bare(head: str) -> str:
     """`groups.laneId` -> `laneId`. Callers in `@call` sites are bare for a
     declaration (caller_at returns blk.name) and qualified for a held literal,
     so the index and the lookup both go through here; a bare name is its own
     bare()."""
-    return re.split(r'[.:]', head)[-1]
+    return re.split(r'[.:>]', head)[-1]
 
 
 def enclosing(spans, line: int) -> Span | None:
@@ -108,7 +115,7 @@ def read_map(path: Path) -> MapSide:
         if raw.startswith('@module '):
             m = SELF_MARK.search(raw)
             ms.self_name = m[1] if m else None
-        elif raw.startswith(('  @fn ', '  @api ', '  @held ', '  @handler ')):
+        elif raw.lstrip().startswith(('@fn ', '@api ', '@held ', '@handler ')):
             m = DECL_ROW.match(raw)
             if not m:
                 raise ValueError(f"{path.name}: unparsed declaration row {raw!r}")
@@ -122,8 +129,8 @@ def read_map(path: Path) -> MapSide:
             # `edit.assign(...)` as an edge the map missed, when the map has
             # never claimed to carry it -- those rows buy attribution (a caller
             # with a span), not a new edge.
-            if not raw.startswith(('  @held ', '  @handler ')):
-                ms.heads.add(m[1])
+            if not raw.lstrip().startswith(('@held ', '@handler ')):
+                ms.heads.add(unqualify(m[1]))
                 ms.bare_heads.add(bare(m[1]))
         elif raw.startswith('  @call '):
             m = CALL_ROW.match(raw)
@@ -146,14 +153,14 @@ def read_map(path: Path) -> MapSide:
                 # Not a declaration, and deliberately unspellable as one, so it
                 # resolves against the chunk rather than through by_name.
                 if caller == '<load>':
-                    ms.sites.add(Site(MAIN_CHUNK, callee, line))
+                    ms.sites.add(Site(MAIN_CHUNK, unqualify(callee), line))
                     ms.spans.add(MAIN_CHUNK)
                     continue
                 span = enclosing(ms.by_name.get(bare(caller), ()), line)
                 if span is None:
                     raise ValueError(f"{path.name}: `@call {callee}` names caller "
                                      f"{caller!r} at {line}, which no declaration contains")
-                ms.sites.add(Site(span, callee, line))
+                ms.sites.add(Site(span, unqualify(callee), line))
     return ms
 
 
diff --git a/tools/map_extract.py b/tools/map_extract.py
index 54c96480..11da19a2 100644
--- a/tools/map_extract.py
+++ b/tools/map_extract.py
@@ -214,6 +214,8 @@ class Block:
     col: int = 0            # column the literal opens at, for attribution
     kind: str = 'fn'        # 'fn' | 'method' | 'dotfn' | 'held' | 'handler'
     indent: int = 0
+    parent: str = ''        # enclosing declaration, for a nested helper
+    depth: int = 0          # how many declarations enclose it
     doc: list[str] = field(default_factory=list)
     annotations: list[Annotation] = field(default_factory=list)
 
@@ -230,6 +232,8 @@ class Decl:
 def decl_head(blk: Block) -> str:
     """How a declaration reads in the map and in the source:
     `tm:byUuid`, `util.print`, or a bare module-local name."""
+    if blk.parent:
+        return f"{blk.parent}>{blk.name}"
     if not blk.owner:
         return blk.name
     return f"{blk.owner}{':' if blk.kind == 'method' else '.'}{blk.name}"
@@ -655,11 +659,11 @@ def parse(path: Path) -> MapFile:
                     cm.dotfns.append(blk)
             continue
 
-        # local function — private helper. Captured at module scope (function
-        # depth 0) wherever a do/if wraps it; true nested closures (depth >=1)
-        # are out of scope.
+        # local function — private helper, at whatever depth it is declared.
+        # A nested one is spelled for the declaration enclosing it (see below),
+        # since a bare name is not unique within the file.
         ml = LOCAL_FN_RE.match(head)
-        if ml and fn_depth[i] == 0:
+        if ml:
             blk = Block(name=ml.group(2), args=ml.group(3).strip(),
                         line=i + 1, kind='fn',
                         doc=collect_doc(lines, i))
@@ -667,9 +671,9 @@ def parse(path: Path) -> MapFile:
             continue
 
         # bare `function name(args)` filling a forward-declared local, inside a
-        # `do` block or at file scope. Module scope only, same as local helpers.
+        # `do` block or at file scope.
         mn = NESTED_FN_RE.match(head)
-        if mn and fn_depth[i] == 0:
+        if mn:
             blk = Block(name=mn.group(2), args=mn.group(3).strip(),
                         line=i + 1, kind='fn',
                         doc=collect_doc(lines, i))
@@ -806,6 +810,19 @@ def parse(path: Path) -> MapFile:
     for blk in fn_blocks + cm.held + cm.handlers:
         blk.end_line = span_end(deltas, level_after, blk.line - 1) + 1
 
+    # A helper declared inside another declaration is spelled for its enclosing
+    # scope, as a held literal is spelled for the table holding it: a bare name
+    # collides with declarations elsewhere in the same file, and the enclosing
+    # scope is the whole of where this one is reachable from.
+    enclosers = sorted((fn_blocks + cm.held + cm.handlers),
+                       key=lambda b: (b.line, b.end_line))
+    for blk in cm.private_fns:
+        outer = [b for b in enclosers
+                 if b.line < blk.line and blk.end_line <= b.end_line]
+        if outer:
+            blk.parent = decl_head(outer[-1])
+            blk.depth = len(outer)
+
     # innermost captured function enclosing a 1-based line -- call attribution.
     # On a block's own first line, `col` splits the construct's head from the
     # literal's body: `wm:subscribe('wiringChanged', function() wv:rebuild() end)`
@@ -986,6 +1003,7 @@ def extract_uses(cm: MapFile, lines: list[str], code_lines: list[str],
     # A module-private helper is called with no receiver at all, so the
     # qualified pass above cannot see it. Masked code, not the `--`-stripped
     # raw lines: a helper name inside a string literal is not a call site.
+    scope_of = visible_ranges(cm)
     for name in sorted({b.name for b in cm.private_fns}):
         # The lookbehind rather than `\b`, which matches after `.` and `:`:
         # `tm:rawIndexFor(` would otherwise satisfy the bare pattern too and
@@ -994,9 +1012,11 @@ def extract_uses(cm: MapFile, lines: list[str], code_lines: list[str],
         rx = re.compile(rf"(?<![.:\w]){re.escape(name)}\s*[({{]")
         for i, code in enumerate(code_lines):
             for m in rx.finditer(code):
-                if (not FN_DECL_PREFIX.fullmatch(code[:m.start()])
+                decl = resolve(scope_of, name, i + 1)
+                if (decl is not None
+                        and not FN_DECL_PREFIX.fullmatch(code[:m.start()])
                         and not shadowed(name, i + 1)):
-                    add_call(name, i + 1, m.start())
+                    add_call(decl_head(decl), i + 1, m.start())
 
     # A helper reached by reference rather than called: bound into a command or
     # export table, or handed over as a callback. 81 helpers have no call site
@@ -1010,14 +1030,17 @@ def extract_uses(cm: MapFile, lines: list[str], code_lines: list[str],
         rx = re.compile(r"(?<![.:\w])" + re.escape(name) + r"\b(?!\s*[({'\"])")
         for i, code in enumerate(code_lines):
             for m in rx.finditer(code):
-                if m.start() < decl_ends[i] or shadowed(name, i + 1):
+                decl = resolve(scope_of, name, i + 1)
+                if (decl is None or m.start() < decl_ends[i]
+                        or shadowed(name, i + 1)):
                     continue
                 if BIND_KEY_LHS.match(code[m.end():]):
                     continue
                 key = (name, i + 1)
                 if key not in bind_seen:
                     bind_seen.add(key)
-                    cm.binds.append((name, caller_at(i + 1, m.start(), load=False), i + 1))
+                    cm.binds.append((decl_head(decl),
+                                     caller_at(i + 1, m.start(), load=False), i + 1))
 
     cm.uses.sort(key=lambda u: (u[0], u[1], u[2]))
     cm.calls.sort(key=lambda c: (c[0], c[2]))
@@ -1025,6 +1048,31 @@ def extract_uses(cm: MapFile, lines: list[str], code_lines: list[str],
     cm.drops.sort(key=lambda d: (d[0], d[2]))
 
 
+def visible_ranges(cm) -> dict:
+    """Name -> the declarations of it and the range each is in scope over. A
+    module-scope helper is visible everywhere; a nested one only inside the
+    declaration enclosing it, from its own line on."""
+    spans = sorted((b.line, b.end_line) for b in
+                   cm.private_fns + cm.methods + cm.dotfns + cm.api
+                   + cm.held + cm.handlers)
+    out: dict = {}
+    for b in cm.private_fns:
+        parents = [(lo, hi) for lo, hi in spans if lo < b.line and b.end_line <= hi]
+        if parents:
+            lo, hi = max(parents)
+            out.setdefault(b.name, []).append((b.line, hi, b))
+        else:
+            out.setdefault(b.name, []).append((1, cm.loc, b))
+    return out
+
+
+def resolve(scope_of: dict, name: str, line: int):
+    """The declaration a bare mention of `name` at `line` reaches: the
+    innermost whose scope covers it, None where none does."""
+    hits = [(lo, b) for lo, hi, b in scope_of.get(name, ()) if lo <= line <= hi]
+    return max(hits, key=lambda h: h[0])[1] if hits else None
+
+
 def extract_fields(code_lines: list[str], skip_receiver: str = '') -> list[tuple[str, str, int]]:
     """(kind 'r'|'w', field, line) triples over masked code.
 
@@ -1220,7 +1268,8 @@ def emit_items(out: list[str], sections: list, items: list,
         for sec in pre:
             if sec[2] not in skip:
                 out.append(f"  -- {sec[2]}")
-        head = f"  {label_prefix}{decl_head(m)}"
+        depth = m.depth if isinstance(m, Block) else 0
+        head = f"{'  ' * (1 + depth)}{label_prefix}{decl_head(m)}"
         out.append(f"{head}{fmt_args(m.args)}  @ {fmt_span(m)}")
         for d in m.doc:
             out.append(f"      -- {d}")
diff --git a/tools/map_index.py b/tools/map_index.py
index 79abfbbe..e59c57a4 100644
--- a/tools/map_index.py
+++ b/tools/map_index.py
@@ -40,7 +40,9 @@ def src_of(mp: Path, text: str) -> str:
 
 def bare_name(kind: str, head: str) -> str:
     if kind == "fn":
-        m = re.match(r"^(\w+)\(", head)
+        # A nested helper is spelled `encloser>name`; sites still spell their
+        # caller bare, so the qualifier comes off here.
+        m = re.match(r"^(?:[\w.:>]+>)?(\w+)\(", head)
         return m.group(1) if m else head
     if kind == "api":
         m = re.match(r"^[\w]+[:.](\w+)\(", head)
```
