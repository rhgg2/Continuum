#!/usr/bin/env python3
"""navigation_survey: what does navigating this repo actually cost?

Mines Claude Code transcripts for navigation behaviour. Tool calls in one
assistant message ran in parallel; calls in consecutive messages are serial,
each blocked on the last. That distinction is the whole measurement -- the
unit of cost is a dependent round-trip, not a token.

    navigation_survey.py <transcript-dir>              full report
    navigation_survey.py <transcript-dir> --limit 40   recent sessions only
    navigation_survey.py <transcript-dir> --json OUT    machine-readable

The transcript dir is ~/.claude/projects/<path-slug>/. Subagent runs live in
the same directory as separate sessions and are excluded from the main-thread
figures (they are bulk readers by design, so they would flatter the numbers).

Re-run after a tooling change: the chain-length histogram and the same-file
scattered-jump rate are the numbers that should move. See
design/map-navigation.md for the findings this was built to produce.

The session running this is itself in the corpus, and is still being written
to -- two runs minutes apart differ slightly because the measuring session
navigated in between. Deterministic on a fixed corpus; not on a live one.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


# ----- Tool taxonomy

# Match on the tool's last `__` segment. The MCP servers were renamed
# (readium -> continuum) partway through the corpus, so fully-qualified names
# are not stable across sessions but the leaf verb is.
READ_TOOLS   = {'Read', 'multi_read', 'multiread', 'NotebookRead'}
SEARCH_TOOLS = {'Grep', 'Glob', 'grep_window'}
EDIT_TOOLS   = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit',
                'apply_patches', 'retry_patches'}
TEST_TOOLS   = {'lua_test_run', 'spec_perturb'}
DOC_TOOLS    = {'reaper_doc_lookup'}
MAP_TOOL     = 'map_query'

# Bash commands that are really navigation wearing a shell hat.
BASH_NAV_RE = re.compile(
    r'^\s*(?:cat|head|tail|less|grep|rg|ag|sed|awk|find|ls|wc|nl)\b'
    r'|[|;]\s*(?:grep|rg|head|tail|sed|awk|wc)\b')

NAV = {'read', 'search', 'map', 'bash-nav'}


def leaf(name: str) -> str:
    return name.rsplit('__', 1)[-1] if '__' in name else name


def classify(name: str, inp: dict) -> str:
    verb = leaf(name)
    if verb in READ_TOOLS:      return 'read'
    if verb in SEARCH_TOOLS:    return 'search'
    if verb == MAP_TOOL:        return 'map'
    if verb in EDIT_TOOLS:      return 'edit'
    if verb in TEST_TOOLS:      return 'test'
    if verb in DOC_TOOLS:       return 'docs'
    if verb == 'reaper_eval':   return 'reaper'
    if name in ('Task', 'Agent'):
        return 'agent'
    if name == 'Bash':
        return 'bash-nav' if BASH_NAV_RE.search(inp.get('command') or '') else 'bash'
    return 'other'


# ----- Target extraction

FILE_IN_CMD_RE = re.compile(r'(?:^|\s)([\w./~-]+\.(?:lua|md|py|map))\b')


def filename_of(path: str) -> str | None:
    """Bare filename for a real-looking source path, else None. Globs,
    patterns and directories are not files and must not count as reads.
    The filename is the right key: one file is referenced by both absolute
    and relative path within a single session."""
    if not path or any(ch in path for ch in '*?['):
        return None
    base = path.rsplit('/', 1)[-1]
    return base if '.' in base else None


def targets(name: str, inp: dict) -> list[str]:
    """Paths a call touched, before filename normalisation."""
    verb = leaf(name)
    out: list[str] = []
    if verb == 'Read':
        if inp.get('file_path'):
            out.append(inp['file_path'])
    elif verb in ('multi_read', 'multiread'):
        out += [r['path'] for r in (inp.get('reads') or [])
                if isinstance(r, dict) and r.get('path')]
    elif verb == 'grep_window':
        out += [p for p in (inp.get('paths') or []) if isinstance(p, str)]
    elif verb in ('Grep', 'Glob'):
        out += [v for k in ('path', 'glob', 'pattern')
                if isinstance(v := inp.get(k), str) and '.' in v]
    elif name == 'Bash':
        out += FILE_IN_CMD_RE.findall(inp.get('command') or '')
    return out


def ranges(call: 'Call') -> list[tuple[str, int, int]]:
    """(filename, start, end) for reads that named an explicit range. A read
    with no range is a whole-file read and has no jump distance."""
    verb, inp = leaf(call.name), call.inp
    out: list[tuple[str, int, int]] = []
    if verb == 'Read' and inp.get('offset'):
        fn = filename_of(inp.get('file_path') or '')
        if fn:
            start = int(inp['offset'])
            out.append((fn, start, start + int(inp.get('limit') or 0)))
    elif verb in ('multi_read', 'multiread'):
        for r in (inp.get('reads') or []):
            if isinstance(r, dict) and r.get('start') and r.get('path'):
                fn = filename_of(r['path'])
                if fn:
                    out.append((fn, int(r['start']), int(r.get('end') or r['start'])))
    return out


# ----- Transcript walk

class Call:
    __slots__ = ('turn', 'name', 'kind', 'inp', 'files', 'err', 'size',
                 'side', 'result')

    def __init__(self, turn, name, kind, inp, files, side):
        self.turn, self.name, self.kind = turn, name, kind
        self.inp, self.files, self.side = inp, files, side
        self.err, self.size, self.result = False, 0, ''


# A nav result can fail loudly (is_error) or quietly (found nothing). Both are
# the same event here: the question came back unanswered.
EMPTY_RE = re.compile(
    r'no matches found|no files found|0 matches|no results|^\s*$'
    r'|found 0 |returned no |does not exist|no such file', re.I)


def result_text(blk: dict) -> str:
    content = blk.get('content')
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(p.get('text', '') for p in content
                         if isinstance(p, dict) and p.get('type') == 'text')
    return ''


def walk(path: Path) -> list[Call]:
    """Ordered tool calls for one session. `turn` numbers assistant messages
    that made calls, so equal turns ran in parallel and consecutive turns are
    dependent."""
    calls: list[Call] = []
    by_id: dict[str, Call] = {}
    turn = 0
    for line in path.open(errors='replace'):
        try:
            rec = json.loads(line)
        except Exception:
            continue
        msg = rec.get('message')
        if not isinstance(msg, dict) or not isinstance(msg.get('content'), list):
            continue
        content, side = msg['content'], bool(rec.get('isSidechain'))

        if rec.get('type') == 'assistant':
            uses = [b for b in content
                    if isinstance(b, dict) and b.get('type') == 'tool_use']
            if not uses:
                continue
            turn += 1
            for b in uses:
                inp = b.get('input') or {}
                name = b.get('name') or '?'
                call = Call(turn, name, classify(name, inp), inp,
                            [f for f in (filename_of(t) for t in targets(name, inp)) if f],
                            side)
                calls.append(call)
                if b.get('id'):
                    by_id[b['id']] = call

        elif rec.get('type') == 'user':
            for b in content:
                if not isinstance(b, dict) or b.get('type') != 'tool_result':
                    continue
                call = by_id.get(b.get('tool_use_id'))
                if not call:
                    continue
                text = result_text(b)
                call.size = len(text)
                call.err = bool(b.get('is_error')) or bool(EMPTY_RE.search(text[:400]))
                if call.kind == 'map':
                    call.result = text[:20000]   # for the term-carry test
    return calls


# ----- Analysis

def nav_runs(ordered: list[int], turns: dict) -> list[list[int]]:
    """Maximal sequences of consecutive turns that each contain a nav call.
    Length is the count of dependent round-trips spent navigating."""
    runs: list[list[int]] = []
    run: list[int] = []
    for t in ordered:
        if any(c.kind in NAV for c in turns[t]) and (not run or t == run[-1] + 1):
            run.append(t)
        else:
            if run:
                runs.append(run)
            run = [t] if any(c.kind in NAV for c in turns[t]) else []
    if run:
        runs.append(run)
    return runs


QUERY_WORD_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]{3,}')
ADJACENT_LINES = 40      # within this many lines, a second read is continuation


def analyse(files: list[Path], mapped: set[str]) -> dict:
    a: dict = dict(
        sessions=0, sessions_with_nav=0,
        tool_freq=Counter(), kind_freq=Counter(), chain_hist=Counter(),
        long_chains=[], reread=Counter(), reread_sessions=0,
        map_then=Counter(), map_pairs=0, map_term_carried=0,
        map_kindless=0, map_same_module=0, map_hop_examples=[],
        read_pairs=0, read_same_file=0, file_walked=Counter(),
        jump_adjacent=0, jump_scattered=0, jump_backward=0, jumps=[],
        mapped_reads=0, mapped_reads_no_map=0,
        empties=0, empty_then=Counter(), bash_nav=Counter(),
        read_whole=0, read_ranged=0,
    )

    for path in files:
        try:
            calls = [c for c in walk(path) if not c.side]
        except Exception:
            continue
        if not calls:
            continue
        a['sessions'] += 1

        for c in calls:
            a['tool_freq'][c.name] += 1
            a['kind_freq'][c.kind] += 1
            if c.kind == 'bash-nav':
                argv = (c.inp.get('command') or '').strip().split()
                if argv:
                    a['bash_nav'][argv[0].rsplit('/', 1)[-1]] += 1
            if leaf(c.name) == 'Read':
                if c.inp.get('offset') or c.inp.get('limit'):
                    a['read_ranged'] += 1
                else:
                    a['read_whole'] += 1

        turns: dict[int, list[Call]] = defaultdict(list)
        for c in calls:
            turns[c.turn].append(c)
        ordered = sorted(turns)

        # ---- dependent navigation chains
        for run in nav_runs(ordered, turns):
            a['chain_hist'][len(run)] += 1
            if len(run) >= 6:
                seq = ['+'.join(sorted({c.kind for c in turns[t] if c.kind in NAV}))
                       for t in run]
                a['long_chains'].append((len(run), path.name, seq))
        if any(c.kind in NAV for c in calls):
            a['sessions_with_nav'] += 1

        # ---- re-reads within a session
        seen: Counter = Counter()
        for c in calls:
            if c.kind not in ('read', 'search', 'bash-nav'):
                continue
            for fn in c.files:
                seen[fn] += 1
                if seen[fn] > 1:
                    a['reread'][fn] += 1
        if any(n > 1 for n in seen.values()):
            a['reread_sessions'] += 1

        # ---- consecutive-turn pair tests
        for i in range(len(ordered) - 1):
            t, u = ordered[i], ordered[i + 1]
            if u != t + 1:
                continue
            prev_map = [c for c in turns[t] if c.kind == 'map']
            next_map = [c for c in turns[u] if c.kind == 'map']
            if prev_map and next_map:
                prev, nxt = prev_map[-1], next_map[0]
                a['map_pairs'] += 1
                if not prev.inp.get('kind') and not nxt.inp.get('kind'):
                    a['map_kindless'] += 1
                if prev.inp.get('module') and prev.inp.get('module') == nxt.inp.get('module'):
                    a['map_same_module'] += 1
                # Did hop N's ANSWER supply hop N+1's question? That is the
                # signature of a graph walked one edge per round trip.
                words = QUERY_WORD_RE.findall(str(nxt.inp.get('query') or ''))
                if words and prev.result and any(w.lower() in prev.result.lower()
                                                 for w in words):
                    a['map_term_carried'] += 1
                    if len(a['map_hop_examples']) < 12:
                        a['map_hop_examples'].append(
                            f"{prev.inp.get('kind') or '?'}:{str(prev.inp.get('query'))[:26]}"
                            f" -> {nxt.inp.get('kind') or '?'}:{str(nxt.inp.get('query'))[:26]}")

            prev_read = [c for c in turns[t] if c.kind == 'read']
            next_read = [c for c in turns[u] if c.kind == 'read']
            if prev_read and next_read:
                a['read_pairs'] += 1
                before = {f for c in prev_read for f in c.files}
                after = {f for c in next_read for f in c.files}
                if before & after:
                    a['read_same_file'] += 1
                    for fn in before & after:
                        a['file_walked'][fn] += 1
                # Sequential chunking or a jump across the file? Only the
                # latter is call-chain following.
                for fa, _, end_prev in [r for c in prev_read for r in ranges(c)]:
                    for fb, start_next, _ in [r for c in next_read for r in ranges(c)]:
                        if fa != fb:
                            continue
                        gap = start_next - end_prev
                        a['jumps'].append(gap)
                        if abs(gap) <= ADJACENT_LINES:
                            a['jump_adjacent'] += 1
                        else:
                            a['jump_scattered'] += 1
                            if gap < 0:
                                a['jump_backward'] += 1

        # ---- map consultation, and empty results
        map_seen = False
        for i, c in enumerate(calls):
            if c.kind == 'map':
                map_seen = True
                nxt = next((x for x in calls[i + 1:] if x.turn > c.turn), None)
                if nxt:
                    a['map_then'][nxt.kind] += 1
            if c.kind == 'read':
                for fn in c.files:
                    if fn.endswith('.lua') and fn[:-4] in mapped:
                        a['mapped_reads'] += 1
                        if not map_seen:
                            a['mapped_reads_no_map'] += 1
            if c.err and c.kind in NAV:
                a['empties'] += 1
                nxt = next((x for x in calls[i + 1:] if x.turn > c.turn), None)
                a['empty_then'][nxt.kind if nxt else 'stop'] += 1

    a['long_chains'].sort(reverse=True)
    return a


def pct(n: int, d: int) -> str:
    return f"{100 * n / d:.1f}%" if d else "n/a"


def report(a: dict) -> str:
    L: list[str] = []
    add = L.append
    add(f"sessions analysed: {a['sessions']}  (with navigation: {a['sessions_with_nav']})")

    add("\n----- Tool mix (main thread; subagent runs excluded)")
    total = sum(a['kind_freq'].values())
    for kind, n in a['kind_freq'].most_common():
        add(f"  {kind:<10} {n:>7}  {pct(n, total):>6}")
    add("\n  top tools:")
    for name, n in a['tool_freq'].most_common(12):
        add(f"    {name:<46} {n:>6}")

    add("\n----- Dependent navigation chains (consecutive turns, each nav)")
    hist = a['chain_hist']
    runs = sum(hist.values())
    turns = sum(k * v for k, v in hist.items())
    peak = max(hist.values()) if hist else 1
    add(f"  runs: {runs}   nav turns inside runs: {turns}")
    for length in sorted(hist):
        if length <= 12 or hist[length] > 3:
            add(f"    len {length:>3}: {hist[length]:>5}  "
                f"{'#' * min(60, hist[length] * 60 // peak)}")
    deep_runs = sum(v for k, v in hist.items() if k >= 4)
    deep_turns = sum(k * v for k, v in hist.items() if k >= 4)
    add(f"  runs of length >=4: {deep_runs} ({pct(deep_runs, runs)} of runs)"
        f"  carrying {deep_turns} turns ({pct(deep_turns, turns)} of nav turns)")
    add("\n  deepest runs (kind per turn):")
    for length, _, seq in a['long_chains'][:8]:
        add(f"    {length:>3}  {' > '.join(seq)[:140]}")

    add("\n----- Walking inside one file (the intra-file question)")
    add(f"  consecutive read-turn pairs:   {a['read_pairs']}")
    add(f"    re-reading the SAME file:    {a['read_same_file']}"
        f" ({pct(a['read_same_file'], a['read_pairs'])})")
    jumps = a['jump_adjacent'] + a['jump_scattered']
    add(f"  same-file pairs with ranges:   {jumps}")
    add(f"    contiguous (|gap| <= {ADJACENT_LINES}):     {a['jump_adjacent']}"
        f" ({pct(a['jump_adjacent'], jumps)})")
    add(f"    scattered jump elsewhere:    {a['jump_scattered']}"
        f" ({pct(a['jump_scattered'], jumps)})")
    add(f"    of those, backwards:         {a['jump_backward']}")
    if a['jumps']:
        sizes = sorted(abs(g) for g in a['jumps'])
        add(f"    median |jump|: {sizes[len(sizes) // 2]} lines   "
            f"p90: {sizes[int(len(sizes) * 0.9)]} lines")
    add("  files most walked within: "
        + ', '.join(f'{k}:{v}' for k, v in a['file_walked'].most_common(8)))

    add("\n----- Re-reads within a session")
    add(f"  sessions with >=1 re-read: {a['reread_sessions']}")
    add(f"  total redundant touches:   {sum(a['reread'].values())}")
    for fn, n in a['reread'].most_common(12):
        add(f"    {fn:<42} {n:>5}")

    add("\n----- map_query behaviour")
    add(f"  what follows a map_query turn: {dict(a['map_then'].most_common())}")
    pairs = a['map_pairs']
    add(f"  consecutive map_query pairs:   {pairs}")
    add(f"    next term present in prev result: {a['map_term_carried']}"
        f" ({pct(a['map_term_carried'], pairs)})   <- graph walking")
    add(f"    no kind filter on either side:    {a['map_kindless']}"
        f" ({pct(a['map_kindless'], pairs)})   <- name fishing")
    add(f"    same module both times:           {a['map_same_module']}"
        f" ({pct(a['map_same_module'], pairs)})")
    for ex in a['map_hop_examples'][:8]:
        add(f"      {ex}")
    add(f"  reads of a .lua that HAS a .map: {a['mapped_reads']}")
    add(f"    with no map_query earlier in session: {a['mapped_reads_no_map']}"
        f" ({pct(a['mapped_reads_no_map'], a['mapped_reads'])})")

    add("\n----- Navigation that came back empty")
    add(f"  count: {a['empties']}   next action: {dict(a['empty_then'].most_common())}")

    add("\n----- Shell-as-navigation")
    add(f"  {dict(a['bash_nav'].most_common(12))}")
    add(f"\n----- Read shape:  whole-file {a['read_whole']}   ranged {a['read_ranged']}")
    return '\n'.join(L)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('dir', help='~/.claude/projects/<path-slug>')
    ap.add_argument('--repo', default=str(Path(__file__).resolve().parent.parent),
                    help='repo root, for the map/ inventory')
    ap.add_argument('--limit', type=int, help='only the N most recent sessions')
    ap.add_argument('--json', help='also write raw counters here')
    args = ap.parse_args(argv[1:])

    mapped = {p.stem for p in (Path(args.repo) / 'map').glob('*.map')}
    files = sorted(Path(args.dir).glob('*.jsonl'))
    if args.limit:
        files = files[-args.limit:]
    if not files:
        print(f"no transcripts in {args.dir}", file=sys.stderr)
        return 1
    print(f"{len(files)} transcripts, {len(mapped)} mapped modules", file=sys.stderr)

    a = analyse(files, mapped)
    print(report(a))
    if args.json:
        Path(args.json).write_text(json.dumps(
            {k: (dict(v) if isinstance(v, Counter) else v)
             for k, v in a.items() if k not in ('long_chains', 'jumps')}, indent=1))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
