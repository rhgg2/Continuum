#!/usr/bin/env python3
"""
map_extract: Lua source → .map semantic-outline.

The .map file is a derived view, not a source of truth. Regenerate after
every change to the .lua. Read .map for orientation; open .lua before editing.

Two module shapes:
  - chunk      — file body IS the constructor; deps come from `(...)`.
                 Loaded via `util.instantiate('name', deps)`. Publishes
                 however it likes: `function self:method(...)`, dot-functions
                 on the returned table (chrome), or a plain descriptor
                 (masterMix) — the deps are what make it a chunk.
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

Both map shapes end with a machine-first `# Fields` section: `@field r|w
<name>  @ <sites>` rows indexing every `.name` read/write (table-constructor
keys count as writes), queried via map_query kind='reads'/'writes'.

Module maps also carry `# Calls (intra-file)`: `@call <callee>  @ <sites>`
rows reversing the file's own `self:foo()` / `tm:foo()` edges, queried via
map_query kind='usedby' alongside the cross-module edges, so "who calls this
method" reads off one query. The callee is spelled as its declaration head
(`tm:byUuid`, `util.print`, bare name for a private fn) and always names a
row in the same map; a `function tm:foo(` head is a declaration, not a site.
A site's caller is the innermost captured declaration enclosing it, `<load>`
where the call is made in the module's own chunk body at load time, and a bare
line number where the extractor could name neither.

Beside it, `# Bindings (by name)`: `@bind <name>  @ <sites>` rows for a private
helper reached by reference rather than called — bound into a command or export
table, or handed over as a callback. Roughly a hundred helpers have no call
site at all, so for those this is the only index naming an entry point;
map_query kind='usedby' returns these rows beside the `@call` ones.

After them, `# Unresolved receivers`: `@drop <target>  @ <sites>` rows for the
qualified call sites *this file's* alias table cannot resolve -- a receiver
bound at runtime (`local ec = tv:ec()`) names no known module, so the edge is
lost rather than absent. Stdlib tables and `reaper`/`gfx` are excluded: an
unresolved `math.floor` is not a lost edge. The rows are candidates, not
confirmed edges -- map_query kind='usedby' resolves the receiver
speculatively and says so in the heading.

A function literal at file scope is captured for attribution: a call site
inside one otherwise renders as a bare line number, with no caller to name.
Three named constructs hold one, told apart at the literal's own position.

A table field -- `render = function()`, the `registerAll{...}` command form,
a dotted assignment target -- gets `# Functions held in tables`:
`@held <table>.<field>(args)  @ <span>`. The qualifier is the table holding
the literal, because a bare field key collides with declarations elsewhere in
the same file.

A wrapper assignment -- `local revert = util.atomic('Revert swing', function(name)`
-- earns a declaration row of its own, `@fn` bare or `@api` on the module's
own table: the wrapper forwards its arguments, and the name is spelled bare at
its use sites, which is what the bare-name @call and @bind passes read.

A handler registration -- `tm:subscribe('rebuild', function(takeChanged)` --
gets `# Handlers registered`: `@handler <recv>:<signal>(args)  @ <span>`, the
spelling the `@use sub tm:rebuild` row already uses for the same object. Held
and handler rows alike carry no doc comments and no annotations.
"""

from __future__ import annotations

import re
from pathlib import Path
from dataclasses import dataclass, field


KINDS = ('invariant', 'contract', 'emits', 'shape', 'reaper')

ANN_RE        = re.compile(rf"^\s*--(\??)({'|'.join(KINDS)}):\s*(.*?)\s*$")
COMMENT_RE    = re.compile(r"^\s*--\s?(.*)$")
SECTION_RE    = re.compile(r"^(\s*)-{5,}\s+(\S.*?)\s*$")
LOCAL_FN_RE   = re.compile(r"^(\s*)local\s+function\s+(\w+)\s*\(([^)]*)\)")
METHOD_RE     = re.compile(r"^(\s*)function\s+(\w+):(\w+)\s*\(([^)]*)\)")
DOT_FN_RE     = re.compile(r"^(\s*)function\s+(\w+)\.(\w+)\s*\(([^)]*)\)")
# Bare `function name(args)` filling a forward-declared local: indented inside
# a `do` block (`local moveCol  do function moveCol(n) ... end end`) or at file
# scope (`local ensureState` ... `function ensureState()`). No global reaches
# here -- luacheck's globals allowlist is reaper/gfx only.
NESTED_FN_RE  = re.compile(r"^(\s*)function\s+([a-z]\w*)\s*\(([^)]*)\)")
# The same fill written as an assignment. Anchored at column 0: indented, this
# spelling is a table-constructor value (`add = function(evt)`, the whole
# registerAll{...} idiom), not a declaration.
ASSIGN_FN_RE  = re.compile(r"^([a-z]\w*)\s*=\s*function\s*\(([^)]*)\)")
# A function literal, wherever on the line it sits. Which of the three named
# constructs holds it is decided at its own position -- see collect_literals.
LITERAL_RE    = re.compile(r"function\s*\(([^)]*)\)")
# 1. A field key immediately before it: `render = function()` and the
# registerAll{...} command form `deleteSel = { function() ... end, 'desc' }`.
# The lookbehind keeps `env.print = function` out -- that is a dotted
# assignment target, which rule 2 reads whole.
FIELD_KEY_RE  = re.compile(r"(?<![\w.:])([A-Za-z_]\w*)\s*=\s*(\{\s*)?$")
# 2. An assignment target opening the statement. A string-literal index names a
# field (`util._stubs['midiManager']`); a computed one names nothing static.
ASSIGN_TGT_RE = re.compile(
    r"""^\s*(?:local\s+)?([A-Za-z_]\w*(?:\.\w+)*)(?:\[\s*['"](\w+)['"]\s*\])?\s*=\s*""")
# and the literal is the whole RHS or an argument of a call. A fallback --
# `local moveHook = deps.moveHook or function() end` -- is neither: capturing
# it would lose the "comes from deps" fact the @state row carries, and claim an
# arity belonging to the fallback rather than to the injected function.
CALL_OPEN_RE  = re.compile(r"^[A-Za-z_][\w.:]*\s*\(")
DROP_SELF_RE  = re.compile(r"^self\s*(?:,\s*)?")
# 3. A call opening the statement, the literal among its arguments. The signal
# is the call's first argument when that is a whole string literal;
# `tracker:register('advBy' .. i, ...)` is not one, and falls back to the method.
HANDLER_RE     = re.compile(r"^\s*([A-Za-z_]\w*)\s*[:.]\s*([A-Za-z_]\w*)\s*\(")
HANDLER_SIG_RE = re.compile(
    r"""^\s*[A-Za-z_]\w*\s*[:.]\s*[A-Za-z_]\w*\s*\(\s*['"]([^'"]+)['"]\s*,""")
# The name an open table constructor is known by: its assignment target or
# field key, else the string that names the call it is an argument of
# (`facade.publish('arrange', {` -- 'arrange' is the spelling call sites use,
# where the receiver is only ever `facade`), else that call's receiver.
QUAL_ASSIGN = re.compile(r"(?:local\s+)?([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=\s*$")
QUAL_STRARG = re.compile(r"""[A-Za-z_]\w*\s*[:.]\s*[A-Za-z_]\w*\s*\(\s*['"]([^'"]+)['"]\s*,\s*$""")
QUAL_RECV   = re.compile(r"([A-Za-z_]\w*)\s*[:.]\s*[A-Za-z_]\w*\s*[({]?\s*$")
# A parameter list may wrap; the head regexes above are line-anchored, so a
# wrapped head matched nothing and the declaration -- with every call site
# inside its body -- vanished from the map. A Lua parameter list holds no
# parens of its own, so the first `)` closes it.
HEAD_OPEN_RE  = re.compile(r"^\s*(?:local\s+)?(?:[A-Za-z_]\w*\s*=\s*)?function\b[^(]*\(")
LOCAL_DECL_RE = re.compile(
    r"^local\s+(\w+(?:\s*,\s*\w+)*)\s*(?:=\s*(.+?))?\s*(?:--.*)?$"
)
REQUIRE_RE    = re.compile(r"""require\s*\(?\s*['"]([^'"]+)['"]""")
INSTANTIATE_RE = re.compile(r"""util\.instantiate\s*\(\s*['"]([^'"]+)['"]""")
# A file-scope forward decl filled further down: `local ec, clipboard, ctx`
# and, 3700 lines later, `ec = util.instantiate('editCursor', {`. Any indent --
# trackerView builds its viewContext inside rebuild() -- because the init-less
# shell decl, not the column, is what confines the match.
FILL_RE       = re.compile(r"^\s*([A-Za-z_]\w*)\s*=\s*(.+)$")
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
# from imports/constructs/self; unresolvable receivers drop. `[({]` rather
# than `\(`: a call whose one argument is a table literal drops the parens.
CALL_RE       = re.compile(r"\b([A-Za-z_]\w*)([.:])([A-Za-z_]\w*)\s*[({]")
# A declaration head (`function tm:foo(`) matches CALL_RE too. Fullmatch this
# against the text before the match to tell a declaration from a call site.
FN_DECL_PREFIX = re.compile(r'\s*(?:local\s+)?function\s+')
# Receivers that are globals rather than instances: an unresolved `math.floor`
# is not a lost edge. Mirrors .luacheckrc's `std = "lua54"` plus
# `globals = { reaper, gfx }`; keep the two in step.
GLOBAL_RECEIVERS = frozenset({
    'coroutine', 'debug', 'io', 'math', 'os', 'package', 'string',
    'table', 'utf8', 'reaper', 'gfx',
})
SUB_RE        = re.compile(r"\b([A-Za-z_]\w*):subscribe\(\s*['\"]([^'\"]+)['\"]")
FORWARD_RE    = re.compile(
    r"\b[A-Za-z_]\w*:forward\(\s*['\"]([^'\"]+)['\"]\s*,\s*([A-Za-z_]\w*)\s*\)"
)

# Field accesses (# Fields section). Dot pass: the lookarounds exclude `..`
# concat; `[A-Za-z_]` excludes the fraction digits of numeric literals.
FIELD_RE      = re.compile(r"(?<!\.)\.(?!\.)([A-Za-z_]\w*)")
# Constructor-key pass: brackets, block keywords, and `ident =` candidates
# (not `==`; dot/colon-prefixed belong to the dot pass).
FIELD_TOK_RE  = re.compile(
    r"[{}()\[\]]"
    r"|\b(?:function|do|then|repeat|elseif|end|until)\b"
    r"|(?<![.\w:])([A-Za-z_]\w*)\s*=(?!=)"
)

# A `local a, b, c` name list is a declaration, not a reference; the statement
# can wrap, so the scan carries a continuation flag.
DECL_LIST_OPEN = re.compile(r"^\s*local\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(,?)")
DECL_LIST_CONT = re.compile(r"^\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(,?)")
# A local of a helper's name is a different variable wearing it.
SHADOW_DECL_RE = re.compile(r"^\s*local\s+(?:function\s+)?([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)")
# `row = row` in an export table: the key is a field, the value the reference.
BIND_KEY_LHS   = re.compile(r"\s*=(?!=)")
# Bare-name mentions of module-private helpers. One scan per line finds every
# candidate; the character after the name sorts it into call, sugar or bind.
HELPER_NAME_RE = re.compile(r"(?<![.:\w])[A-Za-z_]\w*")
CALL_TAIL      = re.compile(r"\s*[({]")
SUGAR_TAIL     = re.compile(r"\s*['\"]")

ATTACH_GAP = 3   # max line gap from annotation to following structural element


Annotation = tuple[str, str, bool, int]   # (kind, body, inferred, line)


@dataclass
class Block:
    name: str
    args: str = ''
    line: int = 0
    end_line: int = 0       # span end (block-depth matched); functions only
    owner: str = ''         # for methods: the receiver
    col: int = 0            # column the literal opens at, for attribution
    kind: str = 'fn'        # 'fn' | 'method' | 'dotfn' | 'held' | 'handler'
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


def decl_head(blk: Block) -> str:
    """How a declaration reads in the map and in the source:
    `tm:byUuid`, `util.print`, or a bare module-local name."""
    if not blk.owner:
        return blk.name
    return f"{blk.owner}{':' if blk.kind == 'method' else '.'}{blk.name}"


@dataclass
class MapFile:
    module: str
    src: Path
    loc: int
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
    held: list[Block] = field(default_factory=list)  # literals in table fields
    handlers: list[Block] = field(default_factory=list)  # literals handed to a registrar
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
    # Intra-file call edges: (callee, caller, line). callee is the
    # declaration head (`tm:byUuid`, `util.print`); caller is the
    # enclosing fn name or None (top-level).
    calls: list[tuple[str, str, int]] = field(default_factory=list)
    # By-name references: (name, caller, line). A private helper bound into a
    # command or export table, or handed over as a callback -- reached without
    # being called.
    binds: list[tuple[str, str, int]] = field(default_factory=list)
    # Qualified call sites whose receiver resolved to nothing: (target, caller,
    # line). Target verbatim, as @use spells it (`ec:setPos`, `batch.commit`).
    drops: list[tuple[str, str, int]] = field(default_factory=list)
    # Field accesses: (kind 'r'|'w', field, line, caller|None).
    fields: list[tuple[str, str, int, str]] = field(default_factory=list)


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


def walk_block_tokens(code: str, stack: list[str], skip_then: int,
                      stop_col: int | None = None) -> int:
    """Apply one line's block tokens to `stack` in place, stopping at
    `stop_col`. Returns the count of upcoming `then`s an `elseif` has already
    spoken for."""
    for m in _BLOCK_TOK.finditer(code):
        if stop_col is not None and m.start() >= stop_col:
            break
        tok = m.group(1)
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
        elif stack:                          # end | until
            stack.pop()
    return skip_then


def function_depth_before(code_lines: list[str]) -> tuple[list[int], list[tuple]]:
    """Per-line count of enclosing *function* bodies, measured before the
    line's own tokens. Distinguishes module-scope helpers (depth 0, captured
    wherever a do/if wraps them) from true nested closures (depth >=1). The
    second return is each line's opening (stack, skip_then), which a
    column-granular query resumes from: a depth alone cannot, because an `end`
    before the column may close a frame the line never opened."""
    depths, states, stack, skip_then = [], [], [], 0
    for code in code_lines:
        depths.append(sum(1 for frame in stack if frame == 'fn'))
        states.append((tuple(stack), skip_then))
        skip_then = walk_block_tokens(code, stack, skip_then)
    return depths, states


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
    """Return (mode, return_target). A chunk is instantiated with deps -- a
    colon-method surface, a `(...)` deref, or a table-literal return; a
    namespace has dot-functions and `return M`. Otherwise script."""
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
    # A `(...)` deref is what instantiation actually looks like, so it outranks
    # publication shape: chrome takes deps and publishes dot-functions,
    # masterMix takes deps and publishes a descriptor table. Reading the return
    # shape alone made those two a namespace and a script, and dropped the deps.
    takes_deps = any(DEP_DEREF_RE.search(r) or DEPS_TABLE_RE.match(r.strip())
                     for r in lines)
    if has_method or takes_deps:
        return ('chunk', return_target)
    if has_dotfn and return_target:
        return ('namespace', return_target)
    if any(RETURN_TBL_RE.match(r.lstrip()) for r in lines):
        return ('chunk', '')         # table-literal return
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


def join_wrapped_heads(lines: list[str]) -> list[str]:
    """`lines` with each wrapped declaration head joined onto its own line."""
    out = list(lines)
    for i, raw in enumerate(lines):
        m = HEAD_OPEN_RE.match(raw)
        if not m or ')' in raw[m.end():]:
            continue
        parts = [raw.rstrip()]
        for nxt in lines[i + 1:]:
            parts.append(nxt.strip())
            if ')' in nxt:
                break
        out[i] = ' '.join(parts)
    return out


def collect_literals(lines: list[str], code_lines: list[str], fn_depth: list[int],
                     declared: set[int], return_target: str
                     ) -> tuple[list[Block], list[Block], list[Block]]:
    """Function literals held at file scope by one of the three named
    constructs -- a table field, a wrapper assignment, a handler registration.
    Returns (held, handlers, named), `named` being the wrapper assignments that
    earn a declaration row of their own.

    Brace depth comes from the masked lines; the constructs are read off the raw
    ones, because strip_code blanks the string that names a published facade or
    a registered signal. Masking preserves length, so the offsets agree.

    The tests interleave with the brace walk rather than preceding it, so each
    fires with the qualifier stack current at the literal's own position. That
    is what makes `facade.publish('sample', { setTrack = function(track) ... })`
    come out `@held sample.setTrack` rather than a handler registered on facade:
    the field key matches at the inner position, and the registration test never
    sees the literal."""
    def qualifier_of(prefix: str) -> str:
        for rx in (QUAL_ASSIGN, QUAL_STRARG, QUAL_RECV):
            m = rx.search(prefix)
            if m:
                return m.group(1)
        return ''

    held: list[Block] = []
    handlers: list[Block] = []
    named: list[Block] = []
    quals: list[tuple[str, int, int]] = []   # (qualifier, line, col) per open `{`

    def capture(i: int, j: int, args: str, statement: bool) -> None:
        # `j` is the literal's own column, and rides on the Block: a site
        # earlier on this line -- the wrapper call, the registrar call -- is
        # made in the enclosing scope, not inside the literal it hands over.
        prefix = lines[i][:j]
        key = FIELD_KEY_RE.search(prefix)
        if key:
            # A `{` opening after the key belongs to the literal itself
            # (`deleteSel = { function() ... end, 'desc' }`) and must not
            # qualify the key with itself; the enclosing table does.
            qual = next((q for q, li, lj in reversed(quals)
                         if q and (li, lj) < (i, key.start(1))), '')
            held.append(Block(name=f'{qual}.{key.group(1)}' if qual else key.group(1),
                              args=args, line=i + 1, col=j, kind='held'))
            return
        if not statement:
            return
        tgt = ASSIGN_TGT_RE.match(prefix)
        rhs = code_lines[i][tgt.end():j].strip() if tgt else ''
        if tgt and (not rhs or (CALL_OPEN_RE.match(rhs)
                                and rhs.count('(') > rhs.count(')'))):
            target, index = tgt.group(1), tgt.group(2)
            owner, _, member = target.rpartition('.')
            if index:
                held.append(Block(name=f'{target}.{index}', args=args,
                                  line=i + 1, col=j, kind='held'))
            elif not owner:
                named.append(Block(name=target, args=args, line=i + 1, col=j, kind='fn'))
            elif owner == return_target:
                named.append(Block(name=member, args=DROP_SELF_RE.sub('', args),
                                   line=i + 1, col=j, owner=owner, kind='method'))
            else:
                held.append(Block(name=target, args=args, line=i + 1, col=j, kind='held'))
            return
        reg = HANDLER_RE.match(prefix)
        if reg and code_lines[i][:j].count('(') > code_lines[i][:j].count(')'):
            sig = HANDLER_SIG_RE.match(prefix)
            handlers.append(
                Block(name=f"{reg.group(1)}:{sig.group(1) if sig else reg.group(2)}",
                      args=args, line=i + 1, col=j, kind='handler'))

    for i, code in enumerate(code_lines):
        # Depth 0 only: a captured declaration opens a function, so these spans
        # can neither contain nor sit inside one, and `innermost` cannot change
        # an answer it already gives. Literals nested inside a declaration stay
        # uncaptured, as nested `local function`s do.
        capturable = fn_depth[i] == 0 and (i + 1) not in declared
        starts = {m.start(): m.group(1).strip() for m in LITERAL_RE.finditer(code)}
        # Rules 2 and 3 read the whole line, so they answer for its first
        # literal only: a second one is nested inside the first, not held by
        # the construct the line opens with.
        outermost = True
        for j, ch in enumerate(code):
            if j in starts:
                if capturable:
                    capture(i, j, starts[j], outermost and not quals)
                outermost = False
            if ch == '{':
                quals.append((qualifier_of(lines[i][:j]), i, j))
            elif ch == '}' and quals:
                quals.pop()
    return held, handlers, named


def parse(path: Path) -> MapFile:
    text = path.read_text()
    lines = text.splitlines()
    head_lines = join_wrapped_heads(lines)
    code_lines = strip_code(text)
    deltas, level_after = block_levels(code_lines)
    fn_depth, fn_states = function_depth_before(code_lines)

    cm = MapFile(module=path.stem, src=path, loc=len(lines))
    cm.mode, cm.return_target = classify(head_lines)
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

        head = head_lines[i]

        # methods on a table — colon receiver. Indented defs count only when the
        # owner is the module's own table; sub-instance methods stay private.
        mm = METHOD_RE.match(head)
        if mm:
            indent, owner, name, args = mm.groups()
            if indent == '' or owner == cm.return_target:
                cm.methods.append(Block(name=name, args=args.strip(),
                                        line=i + 1, owner=owner, kind='method',
                                        doc=collect_doc(lines, i)))
            continue

        # dot functions on a table (no self). Same indent guard as methods.
        md = DOT_FN_RE.match(head)
        if md:
            indent, owner, name, args = md.groups()
            if indent == '' or owner == cm.return_target:
                blk = Block(name=name, args=args.strip(),
                            line=i + 1, owner=owner, kind='dotfn',
                            doc=collect_doc(lines, i))
                # A dot-function on the returned table is public whatever the
                # module's loading shape -- chrome is instantiated with deps and
                # publishes this way.
                if owner == cm.return_target:
                    cm.api.append(blk)
                else:
                    cm.dotfns.append(blk)
            continue

        # local function — private helper. Captured at module scope (function
        # depth 0) wherever a do/if wraps it; true nested closures (depth >=1)
        # are out of scope.
        ml = LOCAL_FN_RE.match(head)
        if ml and fn_depth[i] == 0:
            blk = Block(name=ml.group(2), args=ml.group(3).strip(),
                        line=i + 1, kind='fn',
                        doc=collect_doc(lines, i))
            cm.private_fns.append(blk)
            continue

        # bare `function name(args)` filling a forward-declared local, inside a
        # `do` block or at file scope. Module scope only, same as local helpers.
        mn = NESTED_FN_RE.match(head)
        if mn and fn_depth[i] == 0:
            blk = Block(name=mn.group(2), args=mn.group(3).strip(),
                        line=i + 1, kind='fn',
                        doc=collect_doc(lines, i))
            cm.private_fns.append(blk)
            continue

        # the same fill written as an assignment.
        ma = ASSIGN_FN_RE.match(head)
        if ma and fn_depth[i] == 0:
            blk = Block(name=ma.group(1), args=ma.group(2).strip(),
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

        # Module-level local declarations -- and, at function scope, the ones
        # that name a module instance. continuum wires the whole stack from
        # inside Main(), so a column-0 guard leaves the wiring file's map with
        # no edge to anything it builds; a function-local instance is an alias
        # like any other, it just is not module state.
        indented = raw.startswith((' ', '\t'))
        decl = LOCAL_DECL_RE.match(raw.lstrip() if indented else raw)
        if decl and not LOCAL_FN_RE.match(head):
            names = [n.strip() for n in decl.group(1).split(',')]
            init = (decl.group(2) or '').strip()
            inline_doc = ''
            if '--' in raw and (not init or not init.startswith("'")):
                tail = raw.split('--', 1)[1].strip()
                if tail and (not init or not init.endswith(tail)):
                    inline_doc = tail
            # Classify the declaration.
            if '(...)' in init or init == '...' or DEPS_TABLE_RE.match(raw.strip()):
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
            elif not indented:
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

    # A file-scope forward decl filled further down is a construct, not state:
    # `local ec, clipboard, ctx` (262) with `ec = util.instantiate(...)` at 4004.
    # Only an init-less decl can be filled, which is what keeps the whole-file
    # scan from claiming a table-constructor key that happens to share a name.
    fills: dict[str, tuple[list[Decl], str, int]] = {}
    for i, raw in enumerate(lines):
        mf = FILL_RE.match(raw)
        if not mf:
            continue
        req = REQUIRE_RE.search(mf.group(2))
        inst = INSTANTIATE_RE.search(mf.group(2))
        if req:
            fills.setdefault(mf.group(1), (cm.imports, req.group(1), i + 1))
        elif inst:
            fills.setdefault(mf.group(1), (cm.constructs, inst.group(1), i + 1))

    for bucket in (cm.state, cm.consts):
        for d in list(bucket):
            if d.init:
                continue
            names = [n.strip() for n in d.name.split(',')]
            keep = [n for n in names if n not in fills]
            if keep == names:
                continue
            for n in names:
                if n in fills:
                    target, module, line = fills[n]
                    target.append(Decl(name=n, init=module, line=line,
                                       inline_doc=d.inline_doc))
            if keep:
                d.name = ', '.join(keep)
            else:
                bucket.remove(d)
    cm.imports.sort(key=lambda d: d.line)
    cm.constructs.sort(key=lambda d: d.line)

    fn_blocks = cm.private_fns + cm.methods + cm.dotfns + cm.api
    cm.held, cm.handlers, named = collect_literals(
        lines, code_lines, fn_depth, {b.line for b in fn_blocks}, cm.return_target)
    for blk in named:
        (cm.private_fns if blk.kind == 'fn' else cm.methods).append(blk)
    cm.private_fns.sort(key=lambda b: b.line)

    # Drop forward-decl shells like `local moveCol` that exist only to be filled
    # in below. A shared list (`local colFor, kindAt`) drops only when every name
    # in it was captured; no partial list exists, so none is split. A wrapper
    # assignment is the same object as the declaration row now carried on its
    # line, with its init truncated mid-literal, so it drops on the line alone.
    fn_names = {b.name for b in cm.private_fns}
    captured = {b.line for b in named}
    def is_shell(d: Decl) -> bool:
        return (d.line in captured
                or (not d.init and all(n.strip() in fn_names
                                       for n in d.name.split(','))))
    cm.state = [d for d in cm.state if not is_shell(d)]
    cm.consts = [d for d in cm.consts if not is_shell(d)]

    fn_blocks = cm.private_fns + cm.methods + cm.dotfns + cm.api
    for blk in fn_blocks + cm.held + cm.handlers:
        blk.end_line = span_end(deltas, level_after, blk.line - 1) + 1

    # innermost captured function enclosing a 1-based line -- call attribution.
    # On a block's own first line, `col` splits the construct's head from the
    # literal's body: `wm:subscribe('wiringChanged', function() wv:rebuild() end)`
    # makes both the subscription and the call, and only one of them is inside
    # the handler. A site with no column known is read as inside.
    spans = sorted((b.line, b.end_line, b.name, b.col)
                   for b in fn_blocks + cm.held + cm.handlers)
    def innermost(line: int, col: int | None = None):
        best = None
        for start, end, name, start_col in spans:
            if start <= line <= end and (best is None or start > best[0]):
                if line == start and col is not None and col < start_col:
                    continue
                best = (start, end, name)
        return best

    # Function depth at the site's own column, not at the line's start:
    # `placeCmds[...] = { function() dropAt(i) end, 'Place pooled take' }` makes
    # one call in the chunk body and one inside the literal, and the column is
    # the only thing separating them.
    def depth_at(line: int, col: int | None) -> int:
        stack, skip_then = fn_states[line - 1]
        stack = list(stack)
        walk_block_tokens(code_lines[line - 1], stack, skip_then, col)
        return sum(1 for frame in stack if frame == 'fn')

    # A site no captured declaration encloses is either load-time wiring in the
    # module's own chunk body or a literal the extractor could not name, and a
    # bare line number cannot say which. `<load>` is claimed on the positive
    # depth test above, never as a fallback, so the residue stays honestly
    # unnamed; being no identifier, it also cannot be read as a declaration.
    # `@bind` and `@field` opt out — they answer "where is this referenced",
    # not "who called this", and luac certifies no claim they would carry.
    def caller_at(line: int, col: int | None = None, load: bool = True):
        hit = innermost(line, col)
        if hit:
            return hit[2]
        if load and depth_at(line, col) == 0:
            return '<load>'
        return None

    # A `local` of a helper's name inside a function shadows it for the rest of
    # that function, so every mention from there on belongs to the local.
    # `editCursor:868` says so in a comment; `gridPane:971` does it silently.
    # The depth guard is load-bearing: a module-scope `local function foo` *is*
    # the helper, and would otherwise shadow itself out of existence.
    shadows: dict[str, list[tuple[int, int]]] = {}
    for i, code in enumerate(code_lines):
        m = SHADOW_DECL_RE.match(code) if fn_depth[i] >= 1 else None
        encl = innermost(i + 1) if m else None
        if not encl:
            continue
        for nm in (n.strip() for n in m.group(1).split(',')):
            shadows.setdefault(nm, []).append((i + 1, encl[1]))

    def shadowed(name: str, line: int) -> bool:
        return any(lo <= line <= hi for lo, hi in shadows.get(name, ()))

    attach_annotations(cm)
    for name, lns in cm.signal_lines.items():
        cm.signal_sites[name] = [(caller_at(ln), ln) for ln in lns]
    extract_uses(cm, lines, code_lines, caller_at, shadowed)
    cm.fields = [(kind, name, ln, caller_at(ln, None, load=False))
                 for kind, name, ln in extract_fields(code_lines)]
    return cm


def decl_list_ends(code_lines: list[str]) -> list[int]:
    """Per line, the offset where a `local a, b, c` name list ends (0 if the
    line opens none). Forward-decl lists wrap -- `local addEvent, assignEvent,`
    continues over two more lines in trackerManager -- so the flag carries."""
    out, cont = [], False
    for code in code_lines:
        end = 0
        m = (DECL_LIST_CONT if cont else DECL_LIST_OPEN).match(code)
        if m and re.fullmatch(r'\s*(?:do\s*)?', code[m.end():]):
            end, cont = m.end(1), bool(m.group(2))
        else:
            cont = False
        out.append(end)
    return out


def extract_uses(cm: MapFile, lines: list[str], code_lines: list[str],
                 caller_at, shadowed) -> None:
    """Walk lines collecting outbound edges, and this file's own intra-file
    call graph alongside them -- the receiver-qualified sites the outbound
    pass skips as intra-module, a bare-name pass over module-private helpers,
    and a by-name pass for the helpers reached by reference rather than call.

    Outbound edges store each receiver verbatim (source-faithful: `cm:get`,
    `util.deepClone`); the alias table is consulted only to drop unresolved
    receivers and skip intra-module calls. The querier resolves the short
    name to a module via the self-name registry (unique per module, from
    each map's `self=` marker)."""
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
    def add(kind: str, target: str, line: int, col: int | None = None) -> None:
        key = (kind, target, line)
        if key not in seen:
            seen.add(key)
            cm.uses.append((kind, target, line, caller_at(line, col)))

    for d in cm.imports:
        add('require', d.init, d.line)
    for d in cm.constructs:
        add('require', d.init, d.line)

    # The intra-module calls the loop below skips as non-outbound are this
    # file's own call graph; keep them, keyed by the callee's declaration head
    # so a private fn and a like-named method stay distinct rows.
    members = {b.name: decl_head(b) for b in cm.methods + cm.dotfns + cm.api}
    call_seen: set[tuple[str, int]] = set()
    def add_call(callee: str, line: int, col: int) -> None:
        key = (callee, line)
        if key not in call_seen:
            call_seen.add(key)
            cm.calls.append((callee, caller_at(line, col), line))

    drop_seen: set[tuple[str, int]] = set()
    def add_drop(target: str, line: int, col: int) -> None:
        key = (target, line)
        if key not in drop_seen:
            drop_seen.add(key)
            cm.drops.append((target, caller_at(line, col), line))

    for i, raw in enumerate(lines):
        line = i + 1
        # Strip line-comments to avoid harvesting calls quoted in prose.
        code = raw.split('--', 1)[0] if '--' in raw else raw

        for m in CALL_RE.finditer(code):
            recv, sep, fn = m.group(1), m.group(2), m.group(3)
            mod = aliases.get(recv)
            if not mod:
                # A declaration head matches CALL_RE too, and until now an
                # unresolved one was discarded either way.
                if (recv not in GLOBAL_RECEIVERS
                        and not FN_DECL_PREFIX.fullmatch(code[:m.start()])):
                    add_drop(f'{recv}{sep}{fn}', line, m.start())
                continue
            if fn in ('subscribe', 'forward', 'unsubscribe'):
                continue  # sub/forward are their own edge kinds
            if mod == cm.module and (recv == 'self' or recv == cm.return_target):
                callee = members.get(fn)
                if callee and not FN_DECL_PREFIX.fullmatch(code[:m.start()]):
                    add_call(callee, line, m.start())
                continue  # intra-module call, not an outbound edge
            add('call', f'{recv}{sep}{fn}', line, m.start())

        for m in SUB_RE.finditer(code):
            recv, sig = m.group(1), m.group(2)
            mod = aliases.get(recv)
            if mod:
                add('sub', f'{recv}:{sig}', line, m.start())

        for m in FORWARD_RE.finditer(code):
            # forward(signal, source): outbound edge is to the SOURCE's signal —
            # that's the subscription it establishes. Receiver is the re-fire owner
            # (this file) and is implied by file ownership.
            sig, source = m.group(1), m.group(2)
            mod = aliases.get(source)
            if mod:
                add('forward', f'{source}:{sig}', line, m.start())

    # A module-private helper is mentioned with no receiver at all, so the
    # qualified pass above cannot see it either way it is reached: called, or
    # named without being called -- bound into a command or export table, or
    # handed over as a callback. 81 helpers have no call site at all, and for
    # those the bind index is the only thing that names an entry point.
    #
    # One scan per line rather than one per helper per line: the corpus has
    # names x lines in the millions, and the two reaches are one question about
    # what follows the name. `(` or `{` is a call; `'` or `"` is `f"..."` sugar,
    # which lands in no index at all and which the corpus has none of; anything
    # else is a bind. The lookbehind in HELPER_NAME_RE rather than `\b`, which
    # matches after `.` and `:`: `tm:rawIndexFor(` would otherwise satisfy a
    # bare-name pattern too and emit a second edge keyed `rawIndexFor` for a
    # site already keyed `tm:rawIndexFor`, collapsing the private-fn/method
    # distinction. Masked code, not the `--`-stripped raw lines: a helper name
    # inside a string literal is neither reach.
    # See design/map-navigation.md § Intra-file call edges.
    helpers = {b.name for b in cm.private_fns}
    decl_ends = decl_list_ends(code_lines)
    bind_seen: set[tuple[str, int]] = set()
    for i, code in enumerate(code_lines):
        line = i + 1
        for m in HELPER_NAME_RE.finditer(code):
            name = m.group()
            if name not in helpers or shadowed(name, line):
                continue
            tail = code[m.end():]
            if CALL_TAIL.match(tail):
                if not FN_DECL_PREFIX.fullmatch(code[:m.start()]):
                    add_call(name, line, m.start())
            elif not SUGAR_TAIL.match(tail):
                if m.start() < decl_ends[i] or BIND_KEY_LHS.match(tail):
                    continue
                key = (name, line)
                if key not in bind_seen:
                    bind_seen.add(key)
                    cm.binds.append((name, caller_at(line, m.start(), load=False), line))

    cm.uses.sort(key=lambda u: (u[0], u[1], u[2]))
    cm.calls.sort(key=lambda c: (c[0], c[2]))
    cm.binds.sort(key=lambda b: (b[0], b[2]))
    cm.drops.sort(key=lambda d: (d[0], d[2]))


def extract_fields(code_lines: list[str], skip_receiver: str = '') -> list[tuple[str, str, int]]:
    """(kind 'r'|'w', field, line) triples over masked code.

    Dot pass: `.name` followed by `(`/`{` is call sugar (call edges own it);
    followed by `=` (not `==`) is a write; anything else is a read. Known
    limitation: multi-assignment (`a.x, a.y = …`) classifies `.x` as a read.
    `skip_receiver` drops accesses on one receiver name (specs: `h.<member>`
    is harness plumbing, not a data field).

    Constructor-key pass: `ident =` counts as a write only when the nearest
    open bracket is `{` recorded at the current function depth — so `local
    a, b = …` inside a closure inside a table literal never registers. The
    typed block stack mirrors function_depth_before."""
    out: list[tuple[str, str, int]] = []
    fn_def_prefix = re.compile(r'\s*(?:local\s+)?function\s+[A-Za-z_][\w.]*')
    for i, code in enumerate(code_lines):
        for m in FIELD_RE.finditer(code):
            rest = code[m.end():]
            if re.match(r'\s*[({]', rest):
                # `function recv.name(` declares (writes) the field; any
                # other `.name(` is a call and call edges own it.
                if fn_def_prefix.fullmatch(code[:m.start()]):
                    out.append(('w', m.group(1), i + 1))
                continue
            if skip_receiver:
                recv = re.search(r'([A-Za-z_]\w*)\s*$', code[:m.start()])
                if recv and recv.group(1) == skip_receiver:
                    continue
            kind = 'w' if re.match(r'\s*=(?!=)', rest) else 'r'
            out.append((kind, m.group(1), i + 1))

    blocks: list[str] = []       # 'fn' | 'block'
    brackets: list = []          # ('{', fn_depth) | '(' | '['
    fn_depth, skip_then = 0, 0
    for i, code in enumerate(code_lines):
        for m in FIELD_TOK_RE.finditer(code):
            tok, key = m.group(0), m.group(1)
            if key:
                top = brackets[-1] if brackets else None
                if isinstance(top, tuple) and top[1] == fn_depth:
                    out.append(('w', key, i + 1))
            elif tok == '{':
                brackets.append(('{', fn_depth))
            elif tok in '([':
                brackets.append(tok)
            elif tok in ')]}':
                if brackets:
                    brackets.pop()
            elif tok == 'function':
                blocks.append('fn'); fn_depth += 1
            elif tok in ('do', 'repeat'):
                blocks.append('block')
            elif tok == 'then':
                if skip_then:
                    skip_then -= 1
                else:
                    blocks.append('block')
            elif tok == 'elseif':
                skip_then += 1
            elif blocks:                      # end | until
                if blocks.pop() == 'fn':
                    fn_depth -= 1
    return out


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


# Sites per @field / @call row — keeps a hot field's or a hot callee's rows
# short. Both heads repeat across their chunks and the querier accumulates.
SITE_ROW_CHUNK = 12


def emit_field_rows(out: list[str], fields: list[tuple[str, str, int, str]]) -> None:
    """One `@field <kind> <name>` row per SITE_ROW_CHUNK sites; hot fields
    repeat the head across rows and the querier accumulates them."""
    grouped: dict[tuple[str, str], list[tuple[str, int]]] = {}
    for kind, name, line, caller in fields:
        grouped.setdefault((name, kind), []).append((caller, line))
    for name, kind in sorted(grouped):
        pairs = sorted(grouped[(name, kind)], key=lambda p: p[1])
        for j in range(0, len(pairs), SITE_ROW_CHUNK):
            chunk = render_caller_groups(pairs[j:j + SITE_ROW_CHUNK])
            out.append(f"  @field {kind} {name}  @ {chunk}")


def fmt_args(args: str) -> str:
    return f"({args})" if args else "()"


def fmt_ann(ann: Annotation) -> str:
    kind, body, inferred, line = ann
    mark = '?' if inferred else ''
    return f"@{mark}{kind}  {body}  @ {line}"


def emit_anns(out: list[str], anns: list[Annotation], indent: str) -> None:
    for a in anns:
        out.append(f"{indent}{fmt_ann(a)}")


def fmt_span(blk: Block) -> str:
    return f"{blk.line}-{blk.end_line}" if blk.end_line > blk.line else f"{blk.line}"


def emit_items(out: list[str], sections: list, items: list,
               label_prefix: str) -> None:
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
        head = f"  {label_prefix}{decl_head(m)}"
        out.append(f"{head}{fmt_args(m.args)}  @ {fmt_span(m)}")
        for d in m.doc:
            out.append(f"      -- {d}")
        emit_anns(out, m.annotations, '      ')
        for sec in inside:
            out.append(f"      · {sec[2]}")


def emit(cm: MapFile) -> str:
    out: list[str] = []
    add = out.append
    sections = list(cm.sections)        # consumed by emit_items as we walk

    # Root-relative: map_index turns this into a jump target and flow_extract
    # reopens it as PROJECT_ROOT / src, so a bare basename stops resolving once
    # sources live under src/<stack>/. Last 'src', not the first: a checkout may
    # itself sit under some unrelated src/.
    parts = cm.src.parts
    if 'src' in parts:
        start = len(parts) - parts[::-1].index('src') - 1
        src_rel = '/'.join(parts[start:])
    elif cm.src.parent.name == 'tests':
        src_rel = '/'.join(parts[-2:])
    else:
        src_rel = cm.src.name
    head = f"@module {cm.module}  src={src_rel}  loc={cm.loc}  mode={cm.mode}"
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

    if cm.held:
        # A plain loop, not emit_items: `sections` there is a shared cursor
        # consumed in emit order, and held items span the whole file, so
        # routing them through it would swallow nearly every banner before
        # `# Public API` ran.
        add("# Functions held in tables")
        for blk in cm.held:
            add(f"  @held {blk.name}{fmt_args(blk.args)}  @ {fmt_span(blk)}")
        add('')

    if cm.handlers:
        # A plain loop for the same reason as held, above.
        add("# Handlers registered")
        for blk in cm.handlers:
            add(f"  @handler {blk.name}{fmt_args(blk.args)}  @ {fmt_span(blk)}")
        add('')

    if cm.api:
        owners = sorted({a.owner for a in cm.api})
        add(f"# Public API ({' / '.join(owners)}.*)")
        emit_items(out, sections, cm.api, '@api ')
        add('')

    if cm.methods or cm.dotfns:
        merged = sorted(cm.methods + cm.dotfns, key=lambda b: b.line)
        owners = sorted({m.owner for m in merged})
        # `:` or `.` from how the owner's members are declared -- the module's
        # mode says nothing about the spelling a caller uses.
        label = ' / '.join(o + (':' if any(b.kind == 'method' and b.owner == o for b in merged) else '.') + '*'
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

    if cm.calls:
        add("# Calls (intra-file)")
        # Reverse index: one row per callee, sites grouped under the calling
        # function — "who calls this", which the forward tail on each @fn row
        # cannot answer without reading the whole map.
        by_callee: dict[str, list[tuple[str, int]]] = {}
        for callee, caller, line in cm.calls:
            by_callee.setdefault(callee, []).append((caller, line))
        for callee in sorted(by_callee):
            pairs = sorted(by_callee[callee], key=lambda p: p[1])
            for j in range(0, len(pairs), SITE_ROW_CHUNK):
                chunk = render_caller_groups(pairs[j:j + SITE_ROW_CHUNK])
                add(f"  @call {callee}  @ {chunk}")
        add('')

    if cm.binds:
        add("# Bindings (by name)")
        by_name: dict[str, list[tuple[str, int]]] = {}
        for name, caller, line in cm.binds:
            by_name.setdefault(name, []).append((caller, line))
        for name in sorted(by_name):
            pairs = sorted(by_name[name], key=lambda p: p[1])
            for j in range(0, len(pairs), SITE_ROW_CHUNK):
                chunk = render_caller_groups(pairs[j:j + SITE_ROW_CHUNK])
                add(f"  @bind {name}  @ {chunk}")
        add('')

    if cm.drops:
        add("# Unresolved receivers")
        by_target: dict[str, list[tuple[str, int]]] = {}
        for target, caller, line in cm.drops:
            by_target.setdefault(target, []).append((caller, line))
        for target in sorted(by_target):
            pairs = sorted(by_target[target], key=lambda p: p[1])
            for j in range(0, len(pairs), SITE_ROW_CHUNK):
                chunk = render_caller_groups(pairs[j:j + SITE_ROW_CHUNK])
                add(f"  @drop {target}  @ {chunk}")
        add('')

    if cm.reaper_calls:
        add("# REAPER API surface")
        groups: dict[str, list[str]] = {}
        for r in cm.reaper_calls:
            key = r.split('_', 1)[0] if '_' in r else r
            groups.setdefault(key, []).append(r)
        for _, names in groups.items():
            add(f"  @reaper {', '.join(names)}")

    if cm.fields:
        if out[-1].strip():
            add('')
        add("# Fields (r read / w write incl. constructor keys)")
        emit_field_rows(out, cm.fields)

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
    intent: list[str] = field(default_factory=list)
    helpers: list[Block] = field(default_factory=list)
    cases: list[SpecCase] = field(default_factory=list)
    exercises: list[tuple[str, str]] = field(default_factory=list)  # (module, receiver display)
    surface: list[str] = field(default_factory=list)                # 'pa.frecencyOrder', 'tm:getChannel'
    harness_bits: list[str] = field(default_factory=list)
    uses: list[tuple[str, str, int]] = field(default_factory=list)  # (kind, target, line)
    fields: list[tuple[str, str, int, str]] = field(default_factory=list)  # (kind 'r'|'w', field, line, None)


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
    fn_depth, _ = function_depth_before(code_lines)

    sm = SpecMap(module=path.stem, rel_src='/'.join(path.parts[-3:]),
                 loc=len(lines))
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

    head_lines = join_wrapped_heads(lines)

    for i, raw in enumerate(lines):
        head = head_lines[i]
        mfn = LOCAL_FN_RE.match(head) or NESTED_FN_RE.match(head)
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
    sm.fields = [(kind, name, ln, None)
                 for kind, name, ln in extract_fields(code_lines, skip_receiver='h')]
    return sm


def emit_spec(sm: SpecMap) -> str:
    out: list[str] = []
    add = out.append
    add(f"@spec {sm.module}  src={sm.rel_src}  loc={sm.loc}  cases={len(sm.cases)}")
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

    if sm.fields:
        if out[-1].strip():
            add('')
        add("# Fields (r read / w write incl. constructor keys)")
        emit_field_rows(out, sm.fields)

    return '\n'.join(out).rstrip() + '\n'
