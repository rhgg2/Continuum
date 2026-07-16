#!/usr/bin/env python3
"""
map_extract: Lua source → .map semantic-outline.

The .map file is a derived view, not a source of truth. Regenerate after
every change to the .lua. Read .map for orientation; open .lua before editing.

Two module shapes:
  - chunk      — file body IS the constructor; deps come from `(...)`;
                 returns an instance built with `function self:method(...)`.
                 Loaded via `util.instantiate('name', deps)`.
  - namespace  — `local M = {}` … `function M.fn(...)` … `return M`.
                 Cached by `require`. Pure / stateless.

Author-written annotations:
  --invariant: BODY      always-true property of this module
  --contract:  BODY      promise made to / by callers
  --emits:     NAME -- payload doc
  --shape:     NAME = { … }
  --reaper:    BODY      notes on REAPER surface
A leading `?` (`--?invariant: …`) marks the line as inferred rather than
doc-grounded. Anything else is plain comment prose and is ignored.

Spec files (tests/specs/*_spec.lua) get a sibling grammar: `@spec` header
(cases=N), @exercises/@surface/@harness summary lines, # Intent (the file's
leading comment), # Helpers, # Cases (`@case 'name'  [pure|harness]`), and
the same # Uses section — so map_query's usedby sees spec coverage.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass, field


KINDS = ('invariant', 'contract', 'emits', 'shape', 'reaper')

ANN_RE        = re.compile(rf"^\s*--(\??)({'|'.join(KINDS)}):\s*(.*?)\s*$")
COMMENT_RE    = re.compile(r"^\s*--\s?(.*)$")
SECTION_RE    = re.compile(r"^(\s*)-{5,}\s+(\S.*?)\s*$")
LOCAL_FN_RE   = re.compile(r"^(\s*)local\s+function\s+(\w+)\s*\(([^)]*)\)")
METHOD_RE     = re.compile(r"^(\s*)function\s+(\w+):(\w+)\s*\(([^)]*)\)")
DOT_FN_RE     = re.compile(r"^(\s*)function\s+(\w+)\.(\w+)\s*\(([^)]*)\)")
# Bare `function name(args)` indented inside a `do` block — assignment to a
# forward-declared upvalue (idiom: `local moveCol  do function moveCol(n) ... end end`).
NESTED_FN_RE  = re.compile(r"^(\s+)function\s+([a-z]\w*)\s*\(([^)]*)\)")
LOCAL_DECL_RE = re.compile(
    r"^local\s+(\w+(?:\s*,\s*\w+)*)\s*(?:=\s*(.+?))?\s*(?:--.*)?$"
)
REQUIRE_RE    = re.compile(r"""require\s*\(?\s*['"]([^'"]+)['"]""")
INSTANTIATE_RE = re.compile(r"""util\.instantiate\s*\(\s*['"]([^'"]+)['"]""")
RETURN_RE     = re.compile(r"^return\s+(\w+)\s*$")
RETURN_TBL_RE = re.compile(r"^return\s*\{")
DEP_DEREF_RE  = re.compile(r"\(\s*\.\.\.\s*\)\s*\.(\w+)")
DEPS_TABLE_RE = re.compile(r"^local\s+(\w+)\s*=\s*\.\.\.\s*$")
FIRE_RE       = re.compile(r"""\bfire\(\s*['"]([^'"]+)['"]""")
REAPER_RE     = re.compile(r"\breaper\.(\w+)")
INVERSE_RE    = re.compile(
    r"for\s+\w+\s*,\s*\w+\s+in\s+pairs\(\s*(\w+)\s*\)\s+do\s+(\w+)\[\w+\]\s*=\s*\w+\s+end"
)
EMITS_BODY_RE = re.compile(r"^(\w+)\s*(?:--\s*(.*))?$")

# Outbound edges (Uses pass). Resolved against a per-file alias table built
# from imports/constructs/self; unresolvable receivers drop.
CALL_RE       = re.compile(r"\b([A-Za-z_]\w*)([.:])([A-Za-z_]\w*)\s*\(")
SUB_RE        = re.compile(r"\b([A-Za-z_]\w*):subscribe\(\s*['\"]([^'\"]+)['\"]")
FORWARD_RE    = re.compile(
    r"\b[A-Za-z_]\w*:forward\(\s*['\"]([^'\"]+)['\"]\s*,\s*([A-Za-z_]\w*)\s*\)"
)

ATTACH_GAP = 3   # max line gap from annotation to following structural element


Annotation = tuple[str, str, bool, int]   # (kind, body, inferred, line)


@dataclass
class Block:
    name: str
    args: str = ''
    line: int = 0
    end_line: int = 0       # span end (block-depth matched); functions only
    owner: str = ''         # for methods: the receiver
    kind: str = 'fn'        # 'fn' | 'method' | 'dotfn'
    indent: int = 0
    doc: list[str] = field(default_factory=list)
    annotations: list[Annotation] = field(default_factory=list)


@dataclass
class Decl:
    name: str
    init: str = ''
    line: int = 0
    inline_doc: str = ''
    annotations: list[Annotation] = field(default_factory=list)


@dataclass
class MapFile:
    module: str
    src: Path
    loc: int
    sha: str
    mode: str = 'script'                          # chunk | namespace | script
    return_target: str = ''
    deps: list[str] = field(default_factory=list)
    imports: list[Decl] = field(default_factory=list)
    constructs: list[Decl] = field(default_factory=list)
    state: list[Decl] = field(default_factory=list)
    consts: list[Decl] = field(default_factory=list)
    private_fns: list[Block] = field(default_factory=list)
    methods: list[Block] = field(default_factory=list)
    dotfns: list[Block] = field(default_factory=list)
    api: list[Block] = field(default_factory=list)   # namespace: NS.fn
    sections: list[tuple[int, int, str]] = field(default_factory=list)
    signals: list[str] = field(default_factory=list)
    signal_lines: dict[str, list[int]] = field(default_factory=dict)
    signal_sites: dict[str, list[tuple[str, int]]] = field(default_factory=dict)
    signal_payloads: dict[str, str] = field(default_factory=dict)
    reaper_calls: list[str] = field(default_factory=list)
    reaper_lines: dict[str, list[int]] = field(default_factory=dict)
    module_annotations: list[Annotation] = field(default_factory=list)
    shape_annotations: list[tuple[str, str, bool, int]] = field(default_factory=list)
    pending_annotations: list[tuple[int, str, str, bool]] = field(default_factory=list)
    # Outbound edges: (kind, target, line, caller). caller is the enclosing fn
    # name or None (top-level). kind ∈ {require, call, sub, forward}.
    uses: list[tuple[str, str, int, str]] = field(default_factory=list)


# ----- Helpers

def short_sha(path: Path) -> str:
    try:
        r = subprocess.run(
            ['git', 'log', '-1', '--format=%h', '--', str(path)],
            capture_output=True, text=True, cwd=path.parent,
        )
        return r.stdout.strip() or 'untracked'
    except Exception:
        return 'unknown'


# ----- Block spans (string/comment-aware Lua block-depth)

# Keywords opening / closing an `end`-terminated block. `for`/`while` aren't
# counted -- their `do` is; `elseif` reuses its `if`'s block so its `then` is
# discounted; `repeat` opens and `until` closes.
_OPEN_KW   = re.compile(r'\b(?:function|do|then|repeat)\b')
_CLOSE_KW  = re.compile(r'\b(?:end|until)\b')
_ELSEIF_KW = re.compile(r'\belseif\b')


def strip_code(text: str) -> list[str]:
    """Mask string and comment spans (incl. long brackets [[..]] / --[[..]])
    with spaces so block keywords inside them don't perturb depth counting."""
    n = len(text)
    masked = list(text)
    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if masked[k] != '\n':
                masked[k] = ' '
    i = 0
    long_level = None        # `=` count of an open long bracket, else None
    while i < n:
        c = text[i]
        if long_level is not None:
            if c == ']':
                j = i + 1; eq = 0
                while j < n and text[j] == '=': eq += 1; j += 1
                if eq == long_level and j < n and text[j] == ']':
                    blank(i, j + 1); long_level = None; i = j + 1; continue
            if c != '\n': masked[i] = ' '
            i += 1; continue
        if c == '-' and i + 1 < n and text[i + 1] == '-':
            j = i + 2
            if j < n and text[j] == '[':
                k = j + 1; eq = 0
                while k < n and text[k] == '=': eq += 1; k += 1
                if k < n and text[k] == '[':
                    long_level = eq; blank(i, k + 1); i = k + 1; continue
            j = i
            while j < n and text[j] != '\n': j += 1
            blank(i, j); i = j; continue
        if c == '[':
            j = i + 1; eq = 0
            while j < n and text[j] == '=': eq += 1; j += 1
            if j < n and text[j] == '[':
                long_level = eq; blank(i, j + 1); i = j + 1; continue
            i += 1; continue
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            end = j + 1 if (j < n and text[j] == c) else j
            blank(i, end); i = end; continue
        i += 1
    return ''.join(masked).splitlines()


def block_levels(code_lines: list[str]) -> tuple[list[int], list[int]]:
    """Per-line block delta and running level-after on masked code lines."""
    deltas, after, lvl = [], [], 0
    for code in code_lines:
        d = (len(_OPEN_KW.findall(code)) - len(_ELSEIF_KW.findall(code))
             - len(_CLOSE_KW.findall(code)))
        deltas.append(d); lvl += d; after.append(lvl)
    return deltas, after


def span_end(deltas: list[int], after: list[int], start: int) -> int:
    """0-based end-line index of the block opening at 0-based `start`."""
    open_level = after[start] - deltas[start]
    for j in range(start, len(after)):
        if after[j] <= open_level:
            return j
    return len(after) - 1


# Block keywords in source order, for a typed open/close stack. `for`/`while`
# don't appear -- their `do` opens; `elseif` cancels one upcoming `then`.
_BLOCK_TOK = re.compile(r'\b(function|do|then|repeat|elseif|end|until)\b')


def function_depth_before(code_lines: list[str]) -> list[int]:
    """Per-line count of enclosing *function* bodies, measured before the
    line's own tokens. Distinguishes module-scope helpers (depth 0, captured
    wherever a do/if wraps them) from true nested closures (depth >=1)."""
    depths, stack, skip_then = [], [], 0
    for code in code_lines:
        depths.append(sum(1 for frame in stack if frame == 'fn'))
        for tok in _BLOCK_TOK.findall(code):
            if tok == 'function':
                stack.append('fn')
            elif tok in ('do', 'repeat'):
                stack.append('block')
            elif tok == 'then':
                if skip_then:
                    skip_then -= 1
                else:
                    stack.append('block')
            elif tok == 'elseif':
                skip_then += 1
            elif stack:                      # end | until
                stack.pop()
    return depths


def collect_doc(lines: list[str], i: int) -> list[str]:
    """Walk back from line i collecting contiguous prose comments. Skips
    annotation lines (rendered separately) and banner residue."""
    out: list[str] = []
    j = i - 1
    while j >= 0:
        if ANN_RE.match(lines[j]):
            j -= 1; continue
        m = COMMENT_RE.match(lines[j])
        if not m:
            break
        text = m.group(1).rstrip()
        if not text or text.startswith('-'):
            break
        out.append(text)
        j -= 1
    return list(reversed(out))


def classify(lines: list[str]) -> tuple[str, str]:
    """Return (mode, return_target). Chunks have ≥1 colon-method;
    namespaces have dot-functions and `return M`. Otherwise script."""
    return_target = ''
    has_method = False
    has_dotfn = False
    for raw in lines:
        # Classify on the module's own surface only — col-0 defs. Indented defs
        # may be sub-instance methods (ctx:/owner:) that don't set the shape.
        mth, dot = METHOD_RE.match(raw), DOT_FN_RE.match(raw)
        if mth and mth.group(1) == '':
            has_method = True
        elif dot and dot.group(1) == '':
            has_dotfn = True
        m = RETURN_RE.match(raw.lstrip())
        if m:
            return_target = m.group(1)
    if has_method:
        return ('chunk', return_target)
    if has_dotfn and return_target:
        return ('namespace', return_target)
    if any(RETURN_TBL_RE.match(r.lstrip()) for r in lines):
        return ('chunk', '')         # table-literal return, e.g. chrome.lua
    return ('script', return_target)


def discover_deps(lines: list[str]) -> list[str]:
    """Read deps from `(...).<name>` derefs and from `local X = ...` followed
    by `X.<name>` derefs in subsequent lines."""
    out: list[str] = []
    seen: set[str] = set()
    deps_tables: list[str] = []
    for raw in lines:
        for m in DEP_DEREF_RE.finditer(raw):
            n = m.group(1)
            if n not in seen:
                seen.add(n); out.append(n)
        td = DEPS_TABLE_RE.match(raw.strip())
        if td:
            deps_tables.append(td.group(1))
    if deps_tables:
        # second pass: any `<table>.<name>` in module-level local decls.
        for raw in lines:
            md = LOCAL_DECL_RE.match(raw)
            if not md or not md.group(2):
                continue
            for tbl in deps_tables:
                for m in re.finditer(rf"\b{re.escape(tbl)}\.(\w+)", md.group(2)):
                    n = m.group(1)
                    if n not in seen:
                        seen.add(n); out.append(n)
    return out


def parse(path: Path) -> MapFile:
    text = path.read_text()
    lines = text.splitlines()
    code_lines = strip_code(text)
    deltas, level_after = block_levels(code_lines)
    fn_depth = function_depth_before(code_lines)

    cm = MapFile(module=path.stem, src=path, loc=len(lines), sha=short_sha(path))
    cm.mode, cm.return_target = classify(lines)
    if cm.mode == 'chunk':
        cm.deps = discover_deps(lines)

    for i, raw in enumerate(lines):
        if not raw.strip():
            continue

        ma = ANN_RE.match(raw)
        if ma:
            inferred = (ma.group(1) == '?')
            kind, body = ma.group(2), ma.group(3)
            cm.pending_annotations.append((i + 1, kind, body, inferred))
            if kind == 'emits':
                em = EMITS_BODY_RE.match(body)
                if em:
                    cm.signal_payloads[em.group(1)] = (em.group(2) or '').strip()
            continue

        ms = SECTION_RE.match(raw)
        if ms:
            cm.sections.append((i + 1, len(ms.group(1)), ms.group(2)))
            continue

        # methods on a table — colon receiver. Indented defs count only when the
        # owner is the module's own table; sub-instance methods stay private.
        mm = METHOD_RE.match(raw)
        if mm:
            indent, owner, name, args = mm.groups()
            if indent == '' or owner == cm.return_target:
                cm.methods.append(Block(name=name, args=args.strip(),
                                        line=i + 1, owner=owner, kind='method',
                                        doc=collect_doc(lines, i)))
            continue

        # dot functions on a table (no self). Same indent guard as methods.
        md = DOT_FN_RE.match(raw)
        if md:
            indent, owner, name, args = md.groups()
            if indent == '' or owner == cm.return_target:
                blk = Block(name=name, args=args.strip(),
                            line=i + 1, owner=owner, kind='dotfn',
                            doc=collect_doc(lines, i))
                if cm.mode == 'namespace' and owner == cm.return_target:
                    cm.api.append(blk)
                else:
                    cm.dotfns.append(blk)
            continue

        # local function — private helper. Captured at module scope (function
        # depth 0) wherever a do/if wraps it; true nested closures (depth >=1)
        # are out of scope.
        ml = LOCAL_FN_RE.match(raw)
        if ml and fn_depth[i] == 0:
            blk = Block(name=ml.group(2), args=ml.group(3).strip(),
                        line=i + 1, kind='fn',
                        doc=collect_doc(lines, i))
            cm.private_fns.append(blk)
            continue

        # bare `function name(args)` inside a `do` block — assignment to a
        # forward-declared upvalue. Module scope only, same as local helpers.
        mn = NESTED_FN_RE.match(raw)
        if mn and fn_depth[i] == 0:
            blk = Block(name=mn.group(2), args=mn.group(3).strip(),
                        line=i + 1, kind='fn',
                        doc=collect_doc(lines, i))
            cm.private_fns.append(blk)
            continue

        # signals
        for m in FIRE_RE.finditer(raw):
            n = m.group(1)
            cm.signal_lines.setdefault(n, []).append(i + 1)
            if n not in cm.signals:
                cm.signals.append(n)

        # reaper.X
        for m in REAPER_RE.finditer(raw):
            n = m.group(1)
            cm.reaper_lines.setdefault(n, []).append(i + 1)
            if n not in cm.reaper_calls:
                cm.reaper_calls.append(n)

        # module-level local declarations
        if not raw.startswith((' ', '\t')):
            decl = LOCAL_DECL_RE.match(raw)
            if decl and not LOCAL_FN_RE.match(raw):
                names = [n.strip() for n in decl.group(1).split(',')]
                init = (decl.group(2) or '').strip()
                inline_doc = ''
                if '--' in raw and (not init or not init.startswith("'")):
                    tail = raw.split('--', 1)[1].strip()
                    if tail and (not init or not init.endswith(tail)):
                        inline_doc = tail
                # Classify the declaration.
                if '(...)' in init or init == '...' or DEPS_TABLE_RE.match(raw):
                    # `local x, y = (...).x, (...).y`  or  `local args = ...`
                    continue   # captured under cm.deps
                req = REQUIRE_RE.search(init)
                inst = INSTANTIATE_RE.search(init)
                short = init if len(init) <= 60 else init[:57] + '...'
                if req:
                    cm.imports.append(Decl(name=names[0], init=req.group(1),
                                           line=i + 1, inline_doc=inline_doc))
                elif inst:
                    cm.constructs.append(Decl(name=names[0], init=inst.group(1),
                                              line=i + 1, inline_doc=inline_doc))
                else:
                    # Multi-name decls share one init expression; collapse the
                    # name list into a single entry rather than repeating the
                    # init across each name.
                    name = ', '.join(names)
                    bucket = cm.state if cm.mode == 'chunk' else cm.consts
                    bucket.append(Decl(name=name, init=short, line=i + 1,
                                       inline_doc=inline_doc))

        # `for k,v in pairs(Y) do X[v]=k end` — rewrite empty-table init
        mi = INVERSE_RE.search(raw)
        if mi:
            src_tbl, dst_tbl = mi.group(1), mi.group(2)
            for d in (cm.consts + cm.state):
                if d.name == dst_tbl and d.init == '{}':
                    d.init = f'-- inverse of {src_tbl}'
                    break

    # Drop forward-decl shells like `local moveCol` that exist only to be
    # filled in by a `do function moveCol(...) end end` block.
    fn_names = {b.name for b in cm.private_fns}
    cm.state = [d for d in cm.state if not (not d.init and d.name in fn_names)]
    cm.consts = [d for d in cm.consts if not (not d.init and d.name in fn_names)]

    fn_blocks = cm.private_fns + cm.methods + cm.dotfns + cm.api
    for blk in fn_blocks:
        blk.end_line = span_end(deltas, level_after, blk.line - 1) + 1

    # innermost captured function enclosing a 1-based line -- call attribution
    spans = sorted((b.line, b.end_line, b.name) for b in fn_blocks)
    def caller_at(line: int):
        best = None
        for start, end, name in spans:
            if start <= line <= end and (best is None or start > best[0]):
                best = (start, end, name)
        return best[2] if best else None

    attach_annotations(cm)
    for name, lns in cm.signal_lines.items():
        cm.signal_sites[name] = [(caller_at(ln), ln) for ln in lns]
    extract_uses(cm, lines, caller_at)
    return cm


def extract_uses(cm: MapFile, lines: list[str], caller_at) -> None:
    """Walk lines collecting outbound edges. Stores each receiver verbatim
    (source-faithful: `cm:get`, `util.deepClone`); the alias table is
    consulted only to drop unresolved receivers and skip intra-module calls.
    The querier resolves the short name to a module via the self-name
    registry (unique per module, from each map's `self=` marker)."""
    aliases: dict[str, str] = {}
    for d in cm.imports:    aliases[d.name] = d.init   # name → module
    for d in cm.constructs: aliases[d.name] = d.init
    # Chunk deps (passed via `(...)`) have no statically-known module identity:
    # alias them to themselves so `tm:foo` is emitted verbatim (not dropped),
    # and let the querier resolve the short name through project convention.
    for dep in cm.deps:
        aliases.setdefault(dep, dep)
    if cm.return_target:
        aliases['self'] = cm.module
        aliases[cm.return_target] = cm.module   # `tm:foo()` from within tm.lua

    # require edges fall out of imports/constructs — same data, no per-line scan.
    seen: set[tuple[str, str, int]] = set()
    def add(kind: str, target: str, line: int) -> None:
        key = (kind, target, line)
        if key not in seen:
            seen.add(key)
            cm.uses.append((kind, target, line, caller_at(line)))

    for d in cm.imports:
        add('require', d.init, d.line)
    for d in cm.constructs:
        add('require', d.init, d.line)

    for i, raw in enumerate(lines):
        line = i + 1
        # Strip line-comments to avoid harvesting calls quoted in prose.
        code = raw.split('--', 1)[0] if '--' in raw else raw

        for m in CALL_RE.finditer(code):
            recv, sep, fn = m.group(1), m.group(2), m.group(3)
            mod = aliases.get(recv)
            if not mod or fn in ('subscribe', 'forward', 'unsubscribe'):
                continue  # sub/forward are their own edge kinds
            if mod == cm.module and (recv == 'self' or recv == cm.return_target):
                continue  # intra-module call, not an outbound edge
            add('call', f'{recv}{sep}{fn}', line)

        for m in SUB_RE.finditer(code):
            recv, sig = m.group(1), m.group(2)
            mod = aliases.get(recv)
            if mod:
                add('sub', f'{recv}:{sig}', line)

        for m in FORWARD_RE.finditer(code):
            # forward(signal, source): outbound edge is to the SOURCE's signal —
            # that's the subscription it establishes. Receiver is the re-fire owner
            # (this file) and is implied by file ownership.
            sig, source = m.group(1), m.group(2)
            mod = aliases.get(source)
            if mod:
                add('forward', f'{source}:{sig}', line)

    cm.uses.sort(key=lambda u: (u[0], u[1], u[2]))


def attach_annotations(cm: MapFile) -> None:
    """Attach pending annotations to nearest following structural element.

    Rules:
      shape    → standalone (under # Shapes), never attached.
      emits    → already consumed into cm.signal_payloads.
      others   → grouped into contiguous runs (consecutive lines). A run
                 attaches to the next structural element only if every
                 annotation in the run is within ATTACH_GAP of the target.
                 Otherwise the whole run routes to module_annotations.
                 (Prevents a five-line block of module-wide invariants
                 latching onto the first `require` purely by adjacency.)
    """
    targets: list = []
    targets.extend(cm.imports)
    targets.extend(cm.constructs)
    targets.extend(cm.state)
    targets.extend(cm.consts)
    targets.extend(cm.private_fns)
    targets.extend(cm.methods)
    targets.extend(cm.dotfns)
    targets.extend(cm.api)
    targets.sort(key=lambda t: t.line)

    # Group attachable annotations into contiguous runs.
    pending = [(L, k, b, q) for (L, k, b, q) in cm.pending_annotations
               if k not in ('shape', 'emits')]
    pending.sort(key=lambda x: x[0])
    for L, k, b, q in cm.pending_annotations:
        if k == 'shape':
            cm.shape_annotations.append((k, b, q, L))

    runs: list[list[tuple[int, str, str, bool]]] = []
    for ann in pending:
        if runs and ann[0] == runs[-1][-1][0] + 1:
            runs[-1].append(ann)
        else:
            runs.append([ann])

    for run in runs:
        first_line = run[0][0]
        target = next((t for t in targets if t.line >= first_line), None)
        if target and target.line - first_line <= ATTACH_GAP:
            for L, k, b, q in run:
                target.annotations.append((k, b, q, L))
        else:
            for L, k, b, q in run:
                cm.module_annotations.append((k, b, q, L))


# ----- Emission

def render_caller_groups(pairs: list[tuple[str, int]]) -> str:
    """`(caller, line)` pairs -> `caller:l1,l2 other:l3`; lines with no
    enclosing function appear bare. Callers ordered by their first line."""
    groups: dict[str, list[int]] = {}
    order: list[str] = []
    for caller, line in sorted(pairs, key=lambda p: p[1]):
        if caller not in groups:
            groups[caller] = []
            order.append(caller)
        groups[caller].append(line)
    segs = []
    for caller in order:
        nums = ','.join(str(n) for n in sorted(set(groups[caller])))
        segs.append(f"{caller}:{nums}" if caller else nums)
    return ' '.join(segs)


def fmt_args(args: str) -> str:
    return f"({args})" if args else "()"


def fmt_ann(ann: Annotation) -> str:
    kind, body, inferred, line = ann
    mark = '?' if inferred else ''
    return f"@{mark}{kind}  {body}  @ {line}"


def emit_anns(out: list[str], anns: list[Annotation], indent: str) -> None:
    for a in anns:
        out.append(f"{indent}{fmt_ann(a)}")


def emit_items(out: list[str], sections: list, items: list,
               label_prefix: str, owner_join: str = '') -> None:
    """Render `items` (already line-sorted) interleaving section banners
    that precede them. `sections` is a shared mutable cursor: each banner
    is consumed by the first call whose item-range covers it. Banners
    indented past the items appear as inline sub-bullets."""
    skip = ('PRIVATE', 'PUBLIC', 'Utils')
    for idx, m in enumerate(items):
        next_line = items[idx + 1].line if idx + 1 < len(items) else 10**9
        pre, inside, rest = [], [], []
        for sec in sections:
            line, sec_indent, _ = sec
            if line >= next_line:
                rest.append(sec)
            elif sec_indent <= 0:
                if line < m.line: pre.append(sec)
                else:             rest.append(sec)
            else:
                if line >= m.line: inside.append(sec)
                else:              pre.append(sec)
        sections[:] = rest
        for sec in pre:
            if sec[2] not in skip:
                out.append(f"  -- {sec[2]}")
        if m.owner:
            join = owner_join or (':' if m.kind == 'method' else '.')
            head = f"  {label_prefix}{m.owner}{join}{m.name}"
        else:
            head = f"  {label_prefix}{m.name}"
        loc = f"{m.line}-{m.end_line}" if m.end_line > m.line else f"{m.line}"
        out.append(f"{head}{fmt_args(m.args)}  @ {loc}")
        for d in m.doc:
            out.append(f"      -- {d}")
        emit_anns(out, m.annotations, '      ')
        for sec in inside:
            out.append(f"      · {sec[2]}")


def emit(cm: MapFile) -> str:
    out: list[str] = []
    add = out.append
    sections = list(cm.sections)        # consumed by emit_items as we walk

    head = f"@module {cm.module}  src={cm.src.name}  loc={cm.loc}  sha={cm.sha}  mode={cm.mode}"
    if cm.return_target:
        head += f"  self={cm.return_target}"
    add(head)
    if cm.deps:
        add(f"@deps {', '.join(cm.deps)}")
    add('')

    if cm.module_annotations:
        add("# Invariants & contracts")
        emit_anns(out, cm.module_annotations, '  ')
        add('')

    if cm.shape_annotations:
        add("# Shapes")
        for kind, body, inferred, line in cm.shape_annotations:
            mark = '?' if inferred else ''
            add(f"  @{mark}shape  {body}  @ {line}")
        add('')

    if cm.imports:
        add("# Imports")
        for d in cm.imports:
            tag = 'require' if cm.mode == 'chunk' else 'const'
            line = f"  @{tag} {d.name} = '{d.init}'  @ {d.line}"
            if d.inline_doc:
                line += f"   -- {d.inline_doc}"
            add(line)
            emit_anns(out, d.annotations, '      ')
        add('')

    if cm.constructs:
        add("# Constructed sub-instances")
        width = max(len(d.name) for d in cm.constructs)
        for d in cm.constructs:
            add(f"  @construct {d.name:<{width}} = util.instantiate('{d.init}')  @ {d.line}")
            emit_anns(out, d.annotations, '      ')
        add('')

    if cm.consts:
        add("# Module-level constants")
        for d in cm.consts:
            head = f"  @const {d.name}"
            if d.init.startswith('-- inverse'):
                head += f"  @ {d.line}   {d.init}"
            elif d.init:
                head += f" = {d.init}  @ {d.line}"
            else:
                head += f"  @ {d.line}"
            if d.inline_doc:
                head += f"   -- {d.inline_doc}"
            add(head)
            emit_anns(out, d.annotations, '      ')
        add('')

    if cm.state:
        add("# Private state")
        for d in cm.state:
            head = f"  @state {d.name}"
            if d.init.startswith('-- inverse'):
                head += f"  @ {d.line}   {d.init}"
            elif d.init:
                head += f" = {d.init}  @ {d.line}"
            else:
                head += f"  @ {d.line}"
            if d.inline_doc:
                head += f"   -- {d.inline_doc}"
            add(head)
            emit_anns(out, d.annotations, '      ')
        add('')

    if cm.private_fns:
        add("# Private functions")
        emit_items(out, sections, cm.private_fns, '@fn ')
        add('')

    if cm.api:
        owners = sorted({a.owner for a in cm.api})
        add(f"# Public API ({' / '.join(owners)}.*)")
        emit_items(out, sections, cm.api, '@api ', owner_join='.')
        add('')

    if cm.methods or cm.dotfns:
        merged = sorted(cm.methods + cm.dotfns, key=lambda b: b.line)
        owners = sorted({m.owner for m in merged})
        suffix = '*' if cm.mode == 'chunk' else '.*'
        label = ' / '.join(o + (':' if any(b.kind == 'method' and b.owner == o for b in merged) else '.') + suffix
                           for o in owners)
        add(f"# Public API ({label})")
        emit_items(out, sections, merged, '@api ')
        add('')

    if cm.signals:
        add("# Signals emitted (via util.installHooks)")
        for s in cm.signals:
            line = f"  @emits {s}"
            payload = cm.signal_payloads.get(s)
            if payload:
                line += f"   -- {payload}"
            sites = cm.signal_sites.get(s)
            if sites:
                line += f"   @ {render_caller_groups(sites)}"
            add(line)
        add('')

    if cm.uses:
        add("# Uses (outbound edges)")
        # One row per (kind, target); lines grouped under their caller function
        # so each row reads as a call graph: target <- caller:lines.
        grouped: dict[tuple[str, str], list[tuple[str, int]]] = {}
        order: list[tuple[str, str]] = []
        for kind, target, line, caller in cm.uses:
            key = (kind, target)
            if key not in grouped:
                grouped[key] = []
                order.append(key)
            grouped[key].append((caller, line))
        width = max(len(k) for k, _ in order)
        for kind, target in order:
            sites = render_caller_groups(grouped[(kind, target)])
            add(f"  @use {kind:<{width}} {target}  @ {sites}")
        add('')

    if cm.reaper_calls:
        add("# REAPER API surface")
        groups: dict[str, list[str]] = {}
        for r in cm.reaper_calls:
            key = r.split('_', 1)[0] if '_' in r else r
            groups.setdefault(key, []).append(r)
        for _, names in groups.items():
            add(f"  @reaper {', '.join(names)}")

    return '\n'.join(out).rstrip() + '\n'


# ----- Spec maps (tests/specs/*_spec.lua)

# harness.mk's return-table members (tests/harness.lua) — the module identity
# behind `h.tm:...` receivers. `mm` covers the harness.bareMM convention.
HARNESS_MEMBERS = {
    'fm': 'midiManager', 'mm': 'midiManager', 'tm': 'trackerManager',
    'vm': 'trackerView', 'cm': 'configManager', 'ds': 'dataStore',
    'ps': 'pextStore', 'gm': 'groupManager', 'pa': 'paramAutomation',
    'ccm': 'ccManager', 'cmgr': 'commandManager', 'ec': 'editCursor',
    'clipboard': 'clipboard', 'reaper': 'fakeReaper',
}
# Plumbing receivers, not the surface under test.
SPEC_NOISE = {'util', 'support'}

SPEC_NAME_RE      = re.compile(r"^(\s*)name\s*=\s*(['\"])(.+?)\2\s*(\.\.[^,]*)?,")
SPEC_RUN_RE       = re.compile(r"^(\s*)run\s*=\s*function\s*\(([^)]*)\)")
SPEC_INST_RE      = re.compile(r"\b(\w+)\s*=\s*util\.instantiate\(\s*['\"]([\w.]+)['\"]")
SPEC_MKCALL_RE    = re.compile(r"\bharness\.(mk|bareMM)\b")
SPEC_STATE_RE     = re.compile(r"\b(\w+)\._state\.(\w+)")
SPEC_HLOCAL_RE    = re.compile(r"\blocal\s+(\w+)\s*=\s*h\.(\w+)\s*$")
SPEC_REQ_LOCAL_RE = re.compile(r"^\s*local\s+(\w+)\s*=\s*require\s*\(?\s*['\"]([\w.]+)['\"]")


@dataclass
class SpecCase:
    name: str
    line: int
    end_line: int
    harness: bool


@dataclass
class SpecMap:
    module: str
    rel_src: str
    loc: int
    sha: str
    intent: list[str] = field(default_factory=list)
    helpers: list[Block] = field(default_factory=list)
    cases: list[SpecCase] = field(default_factory=list)
    exercises: list[tuple[str, str]] = field(default_factory=list)  # (module, receiver display)
    surface: list[str] = field(default_factory=list)                # 'pa.frecencyOrder', 'tm:getChannel'
    harness_bits: list[str] = field(default_factory=list)
    uses: list[tuple[str, str, int]] = field(default_factory=list)  # (kind, target, line)


def spec_intent(lines: list[str]) -> list[str]:
    """File-leading comment block; ends at the first blank line after it."""
    out: list[str] = []
    for raw in lines:
        if not raw.strip():
            if out:
                break
            continue
        m = COMMENT_RE.match(raw)
        if not m:
            break
        out.append(m.group(1).rstrip())
    return out


def spec_seed_keys(masked: str) -> list[str]:
    """Immediate keys of every `seed = {…}` table. Operates on string-masked
    text so braces inside string literals can't skew the depth walk."""
    keys: dict[str, None] = {}
    for m in re.finditer(r"\bseed\s*=\s*{", masked):
        depth, i, seg = 1, m.end(), m.end()
        top: list[str] = []
        while i < len(masked) and depth > 0:
            c = masked[i]
            if c == '{':
                if depth == 1:
                    top.append(masked[seg:i])
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 1:
                    seg = i + 1
                elif depth == 0:
                    top.append(masked[seg:i])
            i += 1
        for km in re.finditer(r"(\w+)\s*=", ' '.join(top)):
            keys.setdefault(km.group(1))
    return list(keys)


def parse_spec(path: Path) -> SpecMap:
    text = path.read_text()
    lines = text.splitlines()
    code_lines = strip_code(text)
    deltas, level_after = block_levels(code_lines)
    fn_depth = function_depth_before(code_lines)

    sm = SpecMap(module=path.stem, rel_src='/'.join(path.parts[-3:]),
                 loc=len(lines), sha=short_sha(path))
    sm.intent = spec_intent(lines)

    # Alias table: harness members + instantiated / required modules + locals
    # rebinding a harness member (`local r = h.reaper`).
    aliases = dict(HARNESS_MEMBERS)
    local_aliases: set[str] = set()
    for raw in lines:
        code = raw.split('--', 1)[0] if '--' in raw else raw
        for m in SPEC_INST_RE.finditer(code):
            aliases[m.group(1)] = m.group(2)
            local_aliases.add(m.group(1))
        mreq = SPEC_REQ_LOCAL_RE.match(code)
        if mreq:
            aliases[mreq.group(1)] = mreq.group(2)
            local_aliases.add(mreq.group(1))
        mloc = SPEC_HLOCAL_RE.search(code)
        if mloc and mloc.group(2) in HARNESS_MEMBERS:
            aliases[mloc.group(1)] = HARNESS_MEMBERS[mloc.group(2)]
            local_aliases.add(mloc.group(1))

    pending: list[tuple[str, str, int]] = []   # (indent, name, 1-based line)
    exercised: dict[str, str] = {}             # module -> receiver display
    surface: dict[tuple[str, str], str] = {}   # (module, fn) -> display
    fake_calls: dict[str, None] = {}
    state_pokes: dict[str, None] = {}
    mk_forms: dict[str, None] = {}

    for i, raw in enumerate(lines):
        mfn = LOCAL_FN_RE.match(raw) or NESTED_FN_RE.match(raw)
        if mfn and fn_depth[i] == 0:
            blk = Block(name=mfn.group(2), args=mfn.group(3).strip(),
                        line=i + 1, kind='fn', doc=collect_doc(lines, i))
            blk.end_line = span_end(deltas, level_after, i) + 1
            sm.helpers.append(blk)

        mn = SPEC_NAME_RE.match(raw)
        if mn:
            name = mn.group(3) + (' ..' if mn.group(4) else '')
            pending.append((mn.group(1), name, i + 1))

        mr = SPEC_RUN_RE.match(raw)
        if mr:
            # The case's own `name =` shares the run line's indent; deeper
            # name= keys are data inside the case, not case names.
            picked = next((c for c in reversed(pending) if c[0] == mr.group(1)),
                          pending[-1] if pending else None)
            if picked:
                sm.cases.append(SpecCase(
                    name=picked[1], line=picked[2],
                    end_line=span_end(deltas, level_after, i) + 1,
                    harness='harness' in mr.group(2)))
                pending.clear()

        code = raw.split('--', 1)[0] if '--' in raw else raw
        for m in SPEC_MKCALL_RE.finditer(code):
            mk_forms.setdefault(m.group(1))
        for m in SPEC_STATE_RE.finditer(code):
            if aliases.get(m.group(1)) == 'fakeReaper':
                state_pokes.setdefault(m.group(2))
        for m in CALL_RE.finditer(code):
            recv, sep, fn = m.group(1), m.group(2), m.group(3)
            mod = aliases.get(recv)
            if not mod or mod in SPEC_NOISE:
                continue
            if mod == 'fakeReaper':
                fake_calls.setdefault(f'{recv}{sep}{fn}')
                continue
            display = recv if recv in local_aliases else f'h.{recv}'
            exercised.setdefault(mod, display)
            surface.setdefault((mod, fn), f'{recv}{sep}{fn}')
            sm.uses.append(('call', f'{recv}{sep}{fn}', i + 1))

    if 'mk' in mk_forms:
        seeds = spec_seed_keys('\n'.join(code_lines))
        sm.harness_bits.append(
            'mk{' + ', '.join(f'seed.{k}' for k in seeds) + '}' if seeds else 'mk')
    if 'bareMM' in mk_forms:
        sm.harness_bits.append('bareMM')
    sm.harness_bits += list(fake_calls) + [f'r._state.{f}' for f in state_pokes]
    sm.exercises = list(exercised.items())
    sm.surface = list(surface.values())
    return sm


def emit_spec(sm: SpecMap) -> str:
    out: list[str] = []
    add = out.append
    add(f"@spec {sm.module}  src={sm.rel_src}  loc={sm.loc}  sha={sm.sha}  cases={len(sm.cases)}")
    if sm.exercises:
        add("@exercises " + ', '.join(f"{mod} ({alias})" for mod, alias in sm.exercises))
    if sm.surface:
        add("@surface   " + ', '.join(sm.surface))
    if sm.harness_bits:
        add("@harness   " + ', '.join(sm.harness_bits))
    add('')

    add("# Intent")
    for line in (sm.intent or ['(none)']):
        add(f"  {line}")
    add('')

    if sm.helpers:
        add("# Helpers")
        for b in sm.helpers:
            loc = f"{b.line}-{b.end_line}" if b.end_line > b.line else f"{b.line}"
            add(f"  @fn {b.name}{fmt_args(b.args)}  @ {loc}")
            for d in b.doc:
                add(f"      -- {d}")
        add('')

    if sm.cases:
        add("# Cases")
        for c in sm.cases:
            tag = 'harness' if c.harness else 'pure'
            add(f"  @case '{c.name}'  [{tag}]  @ {c.line}-{c.end_line}")
        add('')

    if sm.uses:
        add("# Uses (outbound edges)")
        grouped: dict[tuple[str, str], list[tuple[None, int]]] = {}
        order: list[tuple[str, str]] = []
        for kind, target, line in sm.uses:
            key = (kind, target)
            if key not in grouped:
                grouped[key] = []
                order.append(key)
            grouped[key].append((None, line))
        for kind, target in order:
            add(f"  @use {kind} {target}  @ {render_caller_groups(grouped[(kind, target)])}")

    return '\n'.join(out).rstrip() + '\n'


# ----- CLI

def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: map_extract.py <lua-file> [<out-dir>]", file=sys.stderr)
        return 2
    src = Path(argv[1]).resolve()
    out_dir = Path(argv[2]).resolve() if len(argv) > 2 else src.parent / 'map'
    out_dir.mkdir(parents=True, exist_ok=True)
    is_spec = src.parent.name == 'specs'
    text = emit_spec(parse_spec(src)) if is_spec else emit(parse(src))
    out_path = out_dir / (src.stem + '.map')
    out_path.write_text(text)
    print(out_path)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
