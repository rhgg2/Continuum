#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2", "typesafe-sdk>=0.7,<0.8"]
# ///
"""Continuum code_find MCP server.

One tool: code_find. Every fn/api/held/handler declaration in map/*.map is a
unit; each unit's source goes to Jev (TypeSafe's System One model) with the
caller's yes/no questions, and the anchors come back ranked by probability.

Jev reads literally and poorly across indirection, so the caller writes each
condition outright and the state holds only the unit's source and the caller's
definitions. Sources: docs.typesafe.ai, model-jaggedness/jev-1.13.
"""

from __future__ import annotations

import asyncio
import logging
import math
import re
import sys
import time
from collections import Counter
from pathlib import Path
from typing import NamedTuple, Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import BaseModel, ConfigDict
from typesafe_sdk import AsyncTypeSafeClient, Noul

ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')
_base_json_schema = ArgModelBase.model_json_schema.__func__


def _untitled(node):
    if isinstance(node, dict):
        return {k: _untitled(v) for k, v in node.items() if k != 'title'}
    if isinstance(node, list):
        return [_untitled(v) for v in node]
    return node


ArgModelBase.model_json_schema = classmethod(
    lambda cls, *a, **kw: _untitled(_base_json_schema(cls, *a, **kw)))

PROJECT_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PROJECT_ROOT / "tools"))
from map_index import MAP_DIR, decl_index  # noqa: E402

MODEL = "jev-1.13.0"
PRICE_PER_MTOK = 0.042
CONCURRENCY = 16

mcp = FastMCP("continuum_jevfind")

# FastMCP's logging setup puts httpx and the SDK at INFO: a line per request,
# thousands per call when the shortlist is off.
for name in ("httpx2", "typesafe_sdk"):
    logging.getLogger(name).setLevel(logging.WARNING)


class Question(BaseModel):
    model_config = ConfigDict(extra='forbid')
    ask: str
    yes: str
    no: str


class Unit(NamedTuple):
    module: str
    kind: str
    head: str
    src: str
    start: int    # the leading comment block's first line, where there is one
    end: int
    text: str


def load_units() -> list[Unit]:
    """Each declaration's span, widened upward over its leading comments so its
    contract lines travel with it. Read fresh per call: maps regenerate on edit."""
    units: list[Unit] = []
    sources: dict[str, list[str]] = {}
    for mp in sorted(MAP_DIR.glob("*.map")):
        for decl in decl_index(mp):
            if decl.src not in sources:
                sources[decl.src] = (PROJECT_ROOT / decl.src).read_text(
                    encoding="utf-8", errors="replace").splitlines()
            lines = sources[decl.src]
            start = decl.start
            while start > 1 and lines[start - 2].lstrip().startswith("--"):
                start -= 1
            end = min(decl.end, len(lines))
            text = "\n".join(f"{n:>5}  {lines[n - 1]}" for n in range(start, end + 1))
            units.append(Unit(mp.stem, decl.kind, decl.head, decl.src, start, end, text))
    return units


STOPWORDS = set("""a an and are as at be by does do every for from how in is it its of on or
    that the this to what when where which who why with code source""".split())


def tokens(text: str) -> list[str]:
    """Whole identifiers and their camelCase parts: `ppqL` matches `ppqL`
    exactly and `ppq` loosely."""
    out = []
    for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text):
        parts = re.findall(r"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])", ident)
        out.append(ident.lower())
        if len(parts) > 1:
            out += [p.lower() for p in parts if len(p) > 1]
    return [w for w in out if w not in STOPWORDS]


def bm25_shortlist(units: list[Unit], query: str, k: int) -> list[Unit]:
    docs = [Counter(tokens(f"{u.module} {u.head} {u.text}")) for u in units]
    lengths = [sum(d.values()) for d in docs]
    mean_length = sum(lengths) / len(lengths)
    doc_freq = Counter(term for d in docs for term in d)
    terms = set(tokens(query))

    def score(i: int) -> float:
        total = 0.0
        for term in terms:
            tf = docs[i].get(term, 0)
            if tf:
                idf = math.log(1 + (len(docs) - doc_freq[term] + 0.5) / (doc_freq[term] + 0.5))
                total += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * lengths[i] / mean_length))
        return total

    scores = [score(i) for i in range(len(units))]
    ranked = sorted(range(len(units)), key=lambda i: scores[i], reverse=True)
    return [units[i] for i in ranked[:k] if scores[i] > 0]


async def judge(units: list[Unit], nouls: dict, define: Optional[str]):
    """One request per unit, every question in it. Failures come back as the
    exception in that unit's slot, so one oversized unit can't sink the call."""
    gate = asyncio.Semaphore(CONCURRENCY)
    spent = {"input_tokens": 0}
    async with AsyncTypeSafeClient(model=MODEL, timeout=120.0) as client:
        async def one(unit: Unit) -> dict:
            state = {"source": unit.text, **({"definitions": define} if define else {})}
            async with gate:
                response = await client.system_one(state=state, questions=nouls)
            spent["input_tokens"] += response.usage.input_tokens or 0
            return {name: response.answers[name].noul for name in nouls}

        answers = await asyncio.gather(*(one(u) for u in units), return_exceptions=True)
    return answers, spent["input_tokens"]


@mcp.tool(structured_output=False)
async def code_find(
    questions: dict[str, Question],
    define: Optional[str] = None,
    paths: Optional[list[str]] = None,
    shortlist: int = 400,
    threshold: float = 0.3,
    max_results: int = 60,
) -> str:
    """Rank the repo's functions by Jev's yes/no judgments about their source.

    Every fn/api/held/handler in map/*.map (~3000 units) is a candidate. A
    BM25 shortlist over the asks and `define` narrows them, then each unit's
    source (leading comments included) goes to Jev with every question.
    Returns `file:start-end` anchors with one probability per question, best
    first; read the source yourself. Recall is high, precision middling: treat
    rows below ~0.8 as leads to check, not findings.

    Writing questions (Jev reads literally and loses track across hops):
      - State the condition outright in `ask`. Not "does this do what the query
        asks"; name the identifier and the act: "Does the code in `source`
        assign a value to a field named exactly `ppqL`?"
      - One judgment per question. A two-way condition ("A to B, or B to A")
        scores one direction well and the other badly: split it.
      - `yes`/`no` give concrete tests, and `no` names the near misses: "only
        read: right of `=`, an argument, a comparison"; "converting pixels
        or quarter notes does not count".
      - `define` pins project terms (sent as `definitions`; refer to it from
        `ask`). It is applied literally, so make it right for every layer:
        e.g. `ppq` is realisation-frame in tm but logical in trackerView.

    Args:
      questions: name -> {ask, yes, no}. All go in each unit's one request.
      define: definitions of project terms, sent beside the source.
      paths: source-path prefixes to judge within (`src/tracker/`,
        `src/shared/timing.lua`), applied before the shortlist. Units per
        stack: tracker ~1300, wiring/shared/arrange ~400 each, the rest
        fewer. Scoping by stack and passing shortlist=0 keeps recall
        without needing the code's vocabulary.
      shortlist: BM25 shortlist size; 0 judges every unit (~45s, ~10c).
        400 costs ~2c and ~6s, but drops code that shares no words with the
        asks or `define`: pure math (`timing.eval(S, x)`) never says
        "logical". Name such functions in `define` when you know them; when
        you don't, pass 0.
      threshold: rows whose best probability is below this are counted,
        not listed.
      max_results: cap on listed rows.
    """
    started = time.perf_counter()
    units = [u for u in load_units()
             if not paths or any(u.src.startswith(p) for p in paths)]
    # define joins the asks: it is where the caller names the vocabulary (`timing.eval`,
    # `applyFactors`) that code doing the job uses without echoing the question's words.
    pool = units if shortlist == 0 else bm25_shortlist(
        units, " ".join([q.ask for q in questions.values()] + [define or ""]), shortlist)
    nouls = {name: Noul(instructions=q.ask, criteria={"true": q.yes, "false": q.no})
             for name, q in questions.items()}
    answers, input_tokens = await judge(pool, nouls, define)

    failed = [(u, a) for u, a in zip(pool, answers) if isinstance(a, BaseException)]
    scored = sorted(((u, a) for u, a in zip(pool, answers) if not isinstance(a, BaseException)),
                    key=lambda ua: max(ua[1].values()), reverse=True)
    listed = [(u, a) for u, a in scored if max(a.values()) >= threshold]
    names = list(questions)
    width = max(len(f"{u.src}:{u.start}-{u.end}") for u, _ in listed) if listed else 0

    cost = input_tokens / 1e6 * PRICE_PER_MTOK
    out = [f"# {len(listed)} at or above {threshold} of {len(pool)} judged "
           f"({'all' if shortlist == 0 else 'shortlist of'} {len(units)} units"
           f"{' under ' + ', '.join(paths) if paths else ''}); "
           f"{input_tokens:,} tokens, ${cost:.3f}, {time.perf_counter() - started:.0f}s",
           "# " + "  ".join(names)]
    for u, a in listed[:max_results]:
        probs = "  ".join(f"{a[n]:.2f}".rjust(len(n)) for n in names)
        out.append(f"  {probs}  {f'{u.src}:{u.start}-{u.end}':<{width}}  "
                   f"{u.module} @{u.kind} {u.head}")
    if len(listed) > max_results:
        out.append(f"# {len(listed) - max_results} more above threshold; raise max_results")
    for u, err in failed:
        out.append(f"# failed {u.src}:{u.start}-{u.end}: {type(err).__name__}: {err}")
    return "\n".join(out)


if __name__ == "__main__":
    mcp.run()
