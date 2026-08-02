#!/usr/bin/env python3
"""
map_oracle: Lua source -> call sites, read off luac's bytecode listing.

An oracle, not a producer. `map_extract.py` derives the corpus's `@call` edges
from a regex pass over the source; this derives the same fact a second and
independent way, so the two can be diffed. A module-level helper called from a
method is, in bytecode, GETUPVAL followed by CALL -- shadowing and aliasing
already resolved by the compiler, which is what the regex pass cannot see.

What it certifies is that a call happened and how it was spelled. It cannot
certify a target module: `ec:row()` compiles to a call on a local whether `ec`
is `editCursor` or anything else.

Hand-run, never wired into a hook. The `luac -p -l -l` listing format is
undocumented and version-coupled -- tolerable for an oracle and not for a
shipped dependency, and the reason this asserts its way through the parse
rather than pattern-matching hopefully. Every count luac declares about a
prototype is checked against what was parsed, because the failure that matters
here is silent: a parser that stops matching reports zero calls, which is zero
disagreements, which is the answer the diff most wants to hear.

  map_oracle.py <file.lua> ...   one record per line, tab-separated:
                                 <src>:<line>  <lo>-<hi>  <kind>  <name>
  map_oracle.py --control        the positive control; non-zero on mismatch
"""

from __future__ import annotations

import argparse
import re
import subprocess
from collections import Counter
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


# ----- Records

@dataclass
class Ins:
    pc: int                 # 1-based, as printed
    line: int               # source line, from the [n] column
    op: str
    args: list[str]         # kept as strings; a trailing 'k' marks a constant
    comment: str            # text after '; ', or ''


@dataclass
class Proto:
    src: str
    lo: int                 # source span, from the header; main is 0,0
    hi: int
    slots: int
    # luac's own declared counts, kept so the parse can be checked against them.
    n_ins: int
    n_locals: int
    n_upvals: int
    n_consts: int
    n_children: int
    ins: list[Ins] = field(default_factory=list)
    local_vars: list[tuple[str, int, int]] = field(default_factory=list)
    # (name, instack, idx). The last two are what let a callee's binding site be
    # walked back up the chain, which is how a file-scope declaration is told
    # from a nested one wearing the same name.
    upvals: list[tuple[str, int, int]] = field(default_factory=list)
    children: list[Proto] = field(default_factory=list)
    parent: Proto | None = None


@dataclass
class Call:
    proto: Proto
    line: int               # the CALL instruction's line
    kind: str
    name: str               # the spelling
    via: Ins | None = None  # the instruction that loaded the callee register


# ----- The listing

HDR    = re.compile(r'^(main|function) <([^:]+):(\d+),(\d+)> \((\d+) instructions? at')
META   = re.compile(r'^(\d+)\+? params?, (\d+) slots?, (\d+) upvalues?, '
                    r'(\d+) locals?, (\d+) constants?, (\d+) functions?')
INS    = re.compile(r'^\t(\d+)\t\[(\d+)\]\t(\S+)\s*(.*?)(?:\t; (.*))?$')
SEC    = re.compile(r'^(constants|locals|upvalues) \((\d+)\) for')
# Locals and upvalues share a row shape -- index, name, then two numbers whose
# meaning differs (startpc/endpc against instack/idx). The name field is
# `[^\t]*` rather than `\S+` because luac prints loop control variables as
# `(for state)`, and dropping those rows shifts every register->name lookup
# above them.
VARROW = re.compile(r'^\t(\d+)\t([^\t]*)\t(\d+)\t(\d+)$')
CONST  = re.compile(r'^\t(\d+)\t')

UPKEY  = re.compile(r'^(\S+) (".*")$')      # GETTABUP's comment: `_ENV "pairs"`

CALL_OPS = ('CALL', 'TAILCALL')


@cache
def luac_version() -> str:
    """Guarded once per run: the listing format is undocumented and
    version-coupled, and 5.4's is what every regex here was written against."""
    proc = subprocess.run(['luac', '-v'], capture_output=True, text=True)
    version = proc.stdout.strip()
    if proc.returncode != 0 or not version.startswith('Lua 5.4'):
        raise RuntimeError(f"need luac 5.4; `luac -v` said {version or proc.stderr.strip()!r}")
    return version


def listing(path: Path) -> str:
    luac_version()
    proc = subprocess.run(['luac', '-p', '-l', '-l', str(path)],
                          capture_output=True, text=True)
    # Raised rather than parsed: an empty listing yields zero calls, and zero
    # calls is the one answer a compile failure must not be allowed to give.
    if proc.returncode != 0:
        raise RuntimeError(f"luac failed on {path}: {proc.stderr.strip()}")
    return proc.stdout


def where(proto: Proto, ins: Ins | None = None) -> str:
    """File, prototype span and optionally pc, for an error message: a listing
    failure that doesn't say which of 64 modules it hit is barely a report."""
    at = f"{proto.src} <{proto.lo},{proto.hi}>"
    return f"{at} pc {ins.pc}" if ins else at


def parse_row(proto: Proto, section: str, raw: str) -> None:
    if section == 'code':
        m = INS.match(raw)
        if not m:
            raise ValueError(f"{where(proto)}: unparsed instruction row {raw!r}")
        proto.ins.append(Ins(pc=int(m[1]), line=int(m[2]), op=m[3],
                             args=m[4].split(), comment=m[5] or ''))
    elif section == 'constants':
        # Counted, not kept: LOADK's own comment carries the value, which is
        # the only place a constant is read from.
        if not CONST.match(raw):
            raise ValueError(f"{where(proto)}: unparsed constant row {raw!r}")
    else:
        m = VARROW.match(raw)
        if not m:
            raise ValueError(f"{where(proto)}: unparsed {section} row {raw!r}")
        if section == 'locals':
            proto.local_vars.append((m[2], int(m[3]), int(m[4])))
        else:
            proto.upvals.append((m[2], int(m[3]), int(m[4])))


def parse_listing(text: str, src: str) -> list[Proto]:
    protos: list[Proto] = []
    consts_seen: list[int] = []           # the one section whose rows aren't kept
    header: re.Match | None = None
    section = ''

    for raw in text.splitlines():
        if not raw:
            continue
        if raw.startswith('\t'):
            if not protos:
                raise ValueError(f"{src}: row before any prototype: {raw!r}")
            if section == 'constants':
                consts_seen[-1] += 1
            parse_row(protos[-1], section, raw)
            continue
        if m := HDR.match(raw):
            header = m
            continue
        if m := META.match(raw):
            if header is None:
                raise ValueError(f"{src}: meta line with no header: {raw!r}")
            protos.append(Proto(src=src, lo=int(header[3]), hi=int(header[4]),
                                slots=int(m[2]), n_ins=int(header[5]),
                                n_upvals=int(m[3]), n_locals=int(m[4]),
                                n_consts=int(m[5]), n_children=int(m[6])))
            consts_seen.append(0)
            header, section = None, 'code'
            continue
        if m := SEC.match(raw):
            section = m[1]
            continue
        raise ValueError(f"{src}: unrecognised listing line: {raw!r}")

    link(protos)
    verify(protos, consts_seen)
    return protos


def link(protos: list[Proto]) -> None:
    """luac prints a prototype then recurses over its children, so they arrive
    pre-order; the meta line's child count is what closes each one, which makes
    the tree unambiguous without reading CLOSURE operands."""
    stack: list[Proto] = []
    for p in protos:
        while stack and len(stack[-1].children) == stack[-1].n_children:
            stack.pop()
        if stack:
            stack[-1].children.append(p)
            p.parent = stack[-1]
        stack.append(p)


def verify(protos: list[Proto], consts_seen: list[int]) -> None:
    """Every count luac declares, against what the parse actually built. This is
    a checksum from the source of record rather than our count of our own parse,
    and it is what makes a parser that silently stops matching impossible -- the
    failure that would otherwise report zero calls, hence zero disagreements.

    It counts the structures, not the lines iterated: a tally of lines seen
    agrees with luac even when a row was read and then dropped, so it would pass
    for exactly the reason it exists to fail. Constants are the one section
    whose rows are deliberately not kept, so they are tallied instead."""
    for proto, n_consts in zip(protos, consts_seen):
        for section, declared, parsed in (
                ('instructions', proto.n_ins,      len(proto.ins)),
                ('locals',       proto.n_locals,   len(proto.local_vars)),
                ('upvalues',     proto.n_upvals,   len(proto.upvals)),
                ('children',     proto.n_children, len(proto.children)),
                ('constants',    proto.n_consts,   n_consts)):
            if parsed != declared:
                raise ValueError(f"{where(proto)}: luac declares {declared} "
                                 f"{section}, parsed {parsed}")


# ----- Which register an opcode writes

WRITES_A = {
    'MOVE', 'LOADI', 'LOADF', 'LOADK', 'LOADKX', 'LOADFALSE', 'LFALSESKIP', 'LOADTRUE',
    'GETUPVAL', 'GETTABUP', 'GETTABLE', 'GETI', 'GETFIELD', 'NEWTABLE', 'ADDI', 'ADDK',
    'SUBK', 'MULK', 'MODK', 'POWK', 'DIVK', 'IDIVK', 'BANDK', 'BORK', 'BXORK', 'SHRI', 'SHLI',
    'ADD', 'SUB', 'MUL', 'MOD', 'POW', 'DIV', 'IDIV', 'BAND', 'BOR', 'BXOR', 'SHL', 'SHR',
    'UNM', 'BNOT', 'NOT', 'LEN', 'CONCAT', 'CLOSURE', 'TESTSET',
}
# MMBIN/MMBINI/MMBINK write nothing of their own: the metamethod result lands
# in the register the preceding arithmetic instruction already targeted, so
# treating them as inert is correct rather than merely harmless.
WRITES_NOTHING = {
    'SETUPVAL', 'SETTABUP', 'SETTABLE', 'SETI', 'SETFIELD', 'MMBIN', 'MMBINI', 'MMBINK',
    'CLOSE', 'TBC', 'JMP', 'EQ', 'LT', 'LE', 'EQK', 'EQI', 'LTI', 'LEI', 'GTI', 'GEI', 'TEST',
    'RETURN', 'RETURN0', 'RETURN1', 'SETLIST', 'EXTRAARG', 'VARARGPREP', 'TAILCALL', 'TFORPREP',
}


def reg(arg: str) -> int:
    """An operand that should name a register. A trailing `k` marks a constant,
    so one here means the opcode's operand layout was misread -- worth a message
    rather than a plausible wrong number."""
    if arg.endswith('k'):
        raise ValueError(f"constant operand {arg!r} where a register was expected")
    return int(arg)


def dest_range(ins: Ins, proto: Proto) -> tuple[int, int] | None:
    """The registers `ins` writes, inclusive, or None for none of them."""
    if ins.op in WRITES_NOTHING:
        return None
    a = reg(ins.args[0])
    if ins.op in WRITES_A:
        return (a, a)
    if ins.op == 'LOADNIL':
        return (a, a + reg(ins.args[1]))
    if ins.op == 'SELF':
        return (a, a + 1)
    if ins.op in ('CALL', 'VARARG'):
        # C is the last operand either way -- CALL prints A B C, VARARG A C.
        # Getting it wrong the over-broad way (every CALL writes to the top of
        # the frame) makes an earlier call swallow later loads, which
        # misreports ordinary sites as `callresult`.
        c = reg(ins.args[-1])
        hi = proto.slots - 1 if c == 0 else a + c - 2      # C == 0 is open-ended
        return (a, hi) if hi >= a else None
    if ins.op in ('FORLOOP', 'FORPREP'):
        return (a, a + 3)
    if ins.op == 'TFORLOOP':
        return (a, a + 2)
    if ins.op == 'TFORCALL':
        return (a + 4, a + 3 + reg(ins.args[-1]))
    # The corpus is fixed and this is hand-run, so a new opcode is news.
    raise ValueError(f"{where(proto, ins)}: unclassified opcode {ins.op!r}")


def writer_of(proto: Proto, r: int, pc: int) -> Ins | None:
    """The nearest earlier instruction whose write range covers register `r`.
    Instruction order, not control flow -- which is also what makes spell()'s
    recursion terminate, since the scan strictly decreases."""
    for ins in reversed(proto.ins[:pc - 1]):
        span = dest_range(ins, proto)
        if span and span[0] <= r <= span[1]:
            return ins
    return None


# ----- Resolving the callee

def local_name(proto: Proto, r: int, pc: int) -> str | None:
    """Register `r` at `pc` is the (r+1)th local live there -- luaF_getlocalname
    transcribed. luac prints startpc/endpc already +1, so they compare directly
    against a 1-based Ins.pc."""
    n = r + 1
    for name, start, end in proto.local_vars:
        if start > pc:
            break
        if pc < end:
            n -= 1
            if n == 0:
                return name
    return None


def unquote(text: str) -> str | None:
    """The string a printed constant spells, or None if it isn't one -- LOADK
    also prints numbers, and a dynamic key must not be read as a constant."""
    if len(text) >= 2 and text.startswith('"') and text.endswith('"'):
        return text[1:-1]
    return None


def key_of(proto: Proto, ins: Ins) -> str:
    """The constant key of an opcode that always carries one in its comment."""
    key = unquote(ins.comment)
    if key is None:
        raise ValueError(f"{where(proto, ins)}: {ins.op} without a quoted key, "
                         f"got {ins.comment!r}")
    return key


def constant_key(proto: Proto, r: int, pc: int) -> str | None:
    """The string constant register `r` holds, if it holds one. A key operand is
    8 bits, so past 255 constants the compiler loads the key into a register
    instead: GETTABUP becomes GETUPVAL _ENV + LOADK + GETTABLE, and SELF keeps
    its opcode but loses its comment. Collapsing those back is what stops the
    overflow inventing a phantom class of unresolvable calls."""
    w = writer_of(proto, r, pc)
    return unquote(w.comment) if w is not None and w.op == 'LOADK' else None


def spell(proto: Proto, r: int, pc: int) -> tuple[str, str]:
    """How register `r` at `pc` was spelled in the source: (kind, name). A
    resolution that cannot be made is tagged `unknown`, never dropped -- a
    dropped site is a defect that cannot be counted."""
    w = writer_of(proto, r, pc)
    if w is None:
        name = local_name(proto, r, pc)
        return ('local', name) if name else ('unknown', f'R{r}')
    if w.op == 'GETUPVAL':
        return ('upvalue', w.comment)
    if w.op == 'GETTABUP':
        m = UPKEY.match(w.comment)
        if not m:
            raise ValueError(f"{where(proto, w)}: unparsed GETTABUP comment {w.comment!r}")
        key = unquote(m[2])
        return ('global', key) if m[1] == '_ENV' else ('upvalue.field', f'{m[1]}.{key}')
    if w.op == 'GETFIELD':
        return ('field', f'{spell(proto, reg(w.args[1]), w.pc)[1]}.{key_of(proto, w)}')
    if w.op == 'SELF':
        # `a:b()` has no dynamic spelling in Lua, so the method name is always
        # a constant -- but on the 8-bit overflow above it arrives in a
        # register and luac prints no comment. 23 sites corpus-wide.
        key = (unquote(w.comment) if w.comment
               else constant_key(proto, reg(w.args[2]), w.pc))
        if key is None:
            raise ValueError(f"{where(proto, w)}: SELF with no recoverable method name")
        return ('method', f'{spell(proto, reg(w.args[1]), w.pc)[1]}:{key}')
    if w.op == 'MOVE':
        b = reg(w.args[1])
        name = local_name(proto, b, w.pc)
        return ('local', name) if name else spell(proto, b, w.pc)
    if w.op == 'GETTABLE':
        base = spell(proto, reg(w.args[1]), w.pc)[1]
        key = constant_key(proto, reg(w.args[2]), w.pc)
        if key is None:
            return ('index', f'{base}[]')
        return ('global', key) if base == '_ENV' else ('field', f'{base}.{key}')
    if w.op == 'GETI':
        return ('index', f'{spell(proto, reg(w.args[1]), w.pc)[1]}[]')
    if w.op == 'CLOSURE':
        return ('closure', '<closure>')
    if w.op in ('CALL', 'VARARG'):
        return ('callresult', '<call result>')
    return ('unknown', f'R{r}')


# ----- Public

def calls(path: Path) -> tuple[list[Proto], list[Call]]:
    """Every prototype in `path`, and every call site across them."""
    protos = parse_listing(listing(path), str(path))
    found = []
    for proto in protos:
        for ins in proto.ins:
            if ins.op in CALL_OPS:
                callee = reg(ins.args[0])
                kind, name = spell(proto, callee, ins.pc)
                # spell() computes the same writer on its way to the spelling.
                # Recomputing it keeps spell() returning a pair, which is worth
                # more here than the one scan it costs.
                found.append(Call(proto=proto, line=ins.line, kind=kind, name=name,
                                  via=writer_of(proto, callee, ins.pc)))
    return protos, found


# ----- Positive control
#
# Hand-counted from the .lua sources before the parser could run. A table
# written from the tool's own output tests nothing but the tool's agreement
# with itself; where hand-count and output disagree the .lua is the arbiter.

# Pinned whole, both directions: 25 records over 13 prototypes, of which
# deriveAssign, tintKey, regionKey and the table.sort comparator have none.
CONTROL_FILE = 'groups.lua'

# (line, lo, hi, kind, name) -- lo-hi being the enclosing prototype's span.
CONTROL_FILE_RECORDS = (
    ( 14,   0,   0, 'global',        'require'),           # main
    ( 20,  19,  24, 'upvalue.field', 'util.clone'),        # groups.resolve
    ( 22,  19,  24, 'global',        'pairs'),
    ( 36,  28,  69, 'global',        'pairs'),             # groups.project
    ( 38,  28,  69, 'upvalue',       'resolve'),
    ( 42,  28,  69, 'global',        'pairs'),
    ( 43,  28,  69, 'upvalue.field', 'util.clone'),
    ( 50,  28,  69, 'global',        'pairs'),
    ( 51,  28,  69, 'field',         'table.sort'),
    ( 56,  28,  69, 'global',        'ipairs'),
    ( 58,  28,  69, 'upvalue.field', 'groups.laneId'),
    ( 58,  28,  69, 'global',        'tostring'),
    ( 74,  72,  88, 'global',        'pairs'),             # groups.reconcile
    ( 77,  72,  88, 'upvalue.field', 'util.add'),
    ( 78,  72,  88, 'upvalue.field', 'util.deepEq'),
    ( 79,  72,  88, 'upvalue.field', 'util.add'),
    ( 82,  72,  88, 'global',        'pairs'),
    ( 84,  72,  88, 'upvalue.field', 'util.add'),
    ( 97,  96,  98, 'global',        'tostring'),          # groups.streamId
    (103, 101, 106, 'method',        'sid:match'),         # groups.shiftStream
    (105, 101, 106, 'global',        'tonumber'),
    (110, 109, 111, 'global',        'tostring'),          # groups.laneId
    (110, 109, 111, 'upvalue.field', 'groups.streamId'),
    (117, 114, 118, 'upvalue.field', 'groups.streamId'),   # groups.inRect
    (132, 130, 133, 'upvalue.field', 'groups.regionKey'),  # groups.outlineKey
)

# Five sites where only the records at that line are pinned, each reaching a
# kind or a trap groups.lua does not. (lo, hi, kind, name).
CONTROL_SITES = {
    # `for fn in pairs(subs) do fn(...) end` in util's fire. The loop control
    # variables print as `(for state)` rows, and dropping those shifts the
    # register->name index enough to lose `fn`.
    ('util.lua', 237): (
        (235, 238, 'global', 'pairs'),
        (235, 238, 'local',  'fn'),
    ),
    # `util.atomic('Resize takes', function() ... end)()` -- the outer call is
    # on the call result, and is the one site whose line is not its loader's.
    ('arrangeView.lua', 201): (
        (193, 209, 'callresult', '<call result>'),
    ),
    # configManager's chunk carries more than 255 constants, so a global
    # arrives as GETUPVAL _ENV + LOADK + GETTABLE rather than GETTABUP.
    ('configManager.lua', 257): (
        (0, 0, 'global', 'ipairs'),
    ),
    # `savers[level](cache[level])` -- a genuinely dynamic index, which the
    # constant-key collapse above must not swallow.
    ('configManager.lua', 525): (
        (518, 528, 'index', 'savers[]'),
    ),
    # `nudgePpq` is declared inside conformOverlaps, so it is a plain local
    # rather than the upvalue a file-scope helper would be.
    ('trackerView.lua', 356): (
        (318, 365, 'local', 'nudgePpq'),
    ),
}


def differences(label: str, expected, actual) -> list[str]:
    """Symmetric difference as multisets: one line per record on either side."""
    exp, act = Counter(expected), Counter(actual)
    fmt = lambda rec: '  '.join(str(part) for part in rec)
    return ([f"  {label}  expected, absent: {fmt(rec)}" for rec in sorted((exp - act).elements())]
            + [f"  {label}  present, unexpected: {fmt(rec)}" for rec in sorted((act - exp).elements())])


def control() -> int:
    problems: list[str] = []

    _, found = calls(ROOT / CONTROL_FILE)
    problems += differences(
        CONTROL_FILE, CONTROL_FILE_RECORDS,
        [(c.line, c.proto.lo, c.proto.hi, c.kind, c.name) for c in found])

    for (src, line), rows in sorted(CONTROL_SITES.items()):
        _, found = calls(ROOT / src)
        problems += differences(
            f"{src}:{line}", rows,
            [(c.proto.lo, c.proto.hi, c.kind, c.name) for c in found if c.line == line])

    pinned = len(CONTROL_FILE_RECORDS) + sum(len(r) for r in CONTROL_SITES.values())
    print(f"control: {pinned} hand-counted records over "
          f"{1 + len({src for src, _ in CONTROL_SITES})} files"
          + (f" -- {len(problems)} disagreements" if problems else " -- all agree"))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


# ----- CLI

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Read call sites off luac's bytecode listing.")
    ap.add_argument('files', nargs='*', type=Path,
                    help="Lua sources to read; one call record per line")
    ap.add_argument('--control', action='store_true',
                    help="run the hand-counted positive control instead")
    args = ap.parse_args()

    if args.control:
        if args.files:
            ap.error("--control reads its own fixed file set; drop the paths")
        return control()
    if not args.files:
        ap.error("nothing to read: pass one or more .lua paths, or --control")

    for path in args.files:
        _, found = calls(path)
        for c in found:
            print(f"{path}:{c.line}\t{c.proto.lo}-{c.proto.hi}\t{c.kind}\t{c.name}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
