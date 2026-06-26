#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Readium docs/navigation MCP server.

Two read-only lookup tools:
  - reaper_doc_lookup: parse the bundled REAPER + ReaImGui HTML and return
    clean prose entries by function/constant name.
  - map_query: structured search over the project's .map semantic outlines.

Split off from the original single-server `readium` so each tool call shows
under its own server name in dispatch and tooling. Sister server:
readium_tests (lua_test_run). Batched writes are handled by the global
`patches` server (mcp__patches__apply_patches).
"""

from __future__ import annotations

import html
import re
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import ConfigDict

# Strict input validation: reject unknown kwargs so silent param-name slips fail loudly.
ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')

PROJECT_ROOT = Path(__file__).resolve().parents[3]
REASCRIPT_HTML = PROJECT_ROOT / "docs" / "REAPER API functions.html"
IMGUI_HTML = PROJECT_ROOT / "docs" / "reaper_imgui_doc.html"
MAP_DIR = PROJECT_ROOT / "map"

mcp = FastMCP("readium_docs")


# ----- HTML helpers ---------------------------------------------------------

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t]+")


def _strip_tags(s: str) -> str:
    s = _TAG.sub("", s)
    s = html.unescape(s)
    s = _WS.sub(" ", s)
    return s.strip()


# ----- ReaScript HTML parser ------------------------------------------------

_RS_ANCHOR = re.compile(r'<a name="([^"]+)"><hr></a><br>')
_RS_LUA_SIG = re.compile(r'<div class="l_func">.*?<code>(.*?)</code>', re.DOTALL)
_RS_FUNC_DIV_END = re.compile(r'<div class="p_func">.*?</div>', re.DOTALL)


def _load_reascript() -> tuple[list[tuple[str, int, int]], str]:
    text = REASCRIPT_HTML.read_text(encoding="utf-8", errors="replace")
    matches = list(_RS_ANCHOR.finditer(text))
    out: list[tuple[str, int, int]] = []
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        name = m.group(1)
        if name == "function_list":
            continue
        out.append((name, start, end))
    return out, text


def _format_reascript_entry(name: str, body: str) -> str:
    lua_sig_m = _RS_LUA_SIG.search(body)
    lua_sig = _strip_tags(lua_sig_m.group(1)) if lua_sig_m else "(no Lua signature)"
    end_m = list(_RS_FUNC_DIV_END.finditer(body))
    prose_html = body[end_m[-1].end():] if end_m else ""
    prose_html = re.sub(r'<br\s*/?>', '\n', prose_html)
    prose = _strip_tags(prose_html).strip()
    return f"=== reascript: {name} ===\n{lua_sig}\n\n{prose}".rstrip()


# ----- ImGui HTML parser ----------------------------------------------------

_IM_ENTRY = re.compile(
    r'<details id="([^"]+)"><summary>([^<]+)</summary>(.*?)</details>',
    re.DOTALL,
)
_IM_LUA_ROW = re.compile(
    r'<tr><th>Lua</th><td><code>(.*?)</code></td></tr>', re.DOTALL
)
_IM_DESC = re.compile(r'<p(?: class="(?!meta)[^"]*")?>(.*?)</p>', re.DOTALL)
_IM_META = re.compile(r'<p class="meta">(.*?)</p>', re.DOTALL)


def _load_imgui() -> dict[str, tuple[str, str]]:
    text = IMGUI_HTML.read_text(encoding="utf-8", errors="replace")
    out: dict[str, tuple[str, str]] = {}
    for m in _IM_ENTRY.finditer(text):
        name = m.group(1)
        summary = m.group(2)
        out[name] = (summary, m.group(3))
    return out


def _format_imgui_entry(name: str, summary: str, body: str) -> str:
    lua_m = _IM_LUA_ROW.search(body)
    lua_sig = _strip_tags(lua_m.group(1)) if lua_m else "(no Lua signature)"
    desc_parts = [_strip_tags(d.group(1)) for d in _IM_DESC.finditer(body)]
    desc = "\n".join(p for p in desc_parts if p)
    meta_m = _IM_META.search(body)
    meta = _strip_tags(meta_m.group(1)) if meta_m else ""
    out = [f"=== imgui {summary.strip()} ===", lua_sig]
    if desc:
        out += ["", desc]
    if meta:
        out += ["", f"({meta})"]
    return "\n".join(out)


def _glob_to_regex(pat: str) -> re.Pattern:
    parts = []
    for ch in pat:
        if ch == "*":
            parts.append(".*")
        elif ch == "?":
            parts.append(".")
        else:
            parts.append(re.escape(ch))
    return re.compile("^" + "".join(parts) + "$", re.IGNORECASE)


@mcp.tool(structured_output=False)
def reaper_doc_lookup(
    name: str,
    kind: str = "auto",
    max_matches: int = 30,
) -> str:
    """Look up a REAPER ReaScript or ReaImGui API entry by name.

    Returns the Lua signature plus the prose description, parsed from the
    bundled docs/ HTML. Replaces grepping the raw 922 KB / 1.2 MB HTML
    files (which return ~50 lines of markup per hit).

    Args:
      name: function or constant name. Case-insensitive. Wildcards `*` and
            `?` are supported — wildcard queries return a one-line index
            (name + Lua signature) instead of full prose, capped at
            `max_matches`.
      kind: "auto" (default) searches both ReaScript and ReaImGui;
            "reascript" or "imgui" restrict to one. ReaScript names are
            CamelCase like `GetMediaItemTrack`. ReaImGui names omit the
            `ImGui_` prefix in the docs (e.g. `Begin`, `Button`).
      max_matches: cap on wildcard match results (default 30).

    Returns:
      Cleanly-formatted entries (one per match) or an "(no match)" line.
    """
    is_pattern = "*" in name or "?" in name
    rx = _glob_to_regex(name) if is_pattern else None

    blocks: list[str] = []
    truncated = False

    if kind in ("auto", "reascript"):
        try:
            entries, text = _load_reascript()
        except FileNotFoundError:
            blocks.append(f"--- ERROR: missing {REASCRIPT_HTML} ---")
        else:
            if is_pattern:
                hits = [(n, s, e) for (n, s, e) in entries if rx.match(n)]
                for n, s, e in hits[:max_matches]:
                    body = text[s:e]
                    sig_m = _RS_LUA_SIG.search(body)
                    sig = _strip_tags(sig_m.group(1)) if sig_m else ""
                    blocks.append(f"reascript {n}: {sig}")
                if len(hits) > max_matches:
                    truncated = True
            else:
                exact = [(n, s, e) for (n, s, e) in entries if n.lower() == name.lower()]
                for n, s, e in exact:
                    blocks.append(_format_reascript_entry(n, text[s:e]))

    if kind in ("auto", "imgui"):
        try:
            im = _load_imgui()
        except FileNotFoundError:
            blocks.append(f"--- ERROR: missing {IMGUI_HTML} ---")
        else:
            names = list(im.keys())
            if is_pattern:
                hits = [n for n in names if rx.match(n)]
                for n in hits[:max_matches]:
                    summary, body = im[n]
                    sig_m = _IM_LUA_ROW.search(body)
                    sig = _strip_tags(sig_m.group(1)) if sig_m else ""
                    blocks.append(f"imgui {summary.strip()}: {sig}")
                if len(hits) > max_matches:
                    truncated = True
            else:
                for n in names:
                    if n.lower() == name.lower():
                        summary, body = im[n]
                        blocks.append(_format_imgui_entry(n, summary, body))

    if not blocks:
        suffix = "" if kind == "auto" else f" (kind={kind})"
        return f"(no match for {name!r}{suffix})"
    if truncated:
        blocks.append(f"--- truncated at {max_matches} matches; narrow the pattern ---")
    return "\n\n".join(blocks)


# ----- map_query ------------------------------------------------------------

_MAP_HEADER = re.compile(r'^@module\s+(\S+)\s+src=(\S+)\s+loc=(\d+)\s+sha=(\S+)')
_DECL = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>fn|api|state|const|require|construct)\s+'
    r'(?P<head>.+?)\s*@\s*(?P<line>\d+)(?:-(?P<end>\d+))?\s*'
    r'(?P<doc>(?:--|·).*)?$'
)
# Annotations: `@invariant`, `@contract`, `@shape`, `@emits`, `@reaper`,
# any of which may carry a leading `?` (`@?invariant …`) for inferred-rather-
# than-doc-grounded variants. `@deps` is rendered on its own line in the header.
_ANN = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>\??(?:invariant|contract|shape|emits|reaper|deps))\s+'
    r'(?P<body>.*)$'
)
# `@use <kind> <target>  @ <caller>:<line>[,<line>] [<caller>:<line>...]`
# Top-level edges (e.g. requires) appear as bare line numbers, no caller.
_USE = re.compile(
    r'^\s*@use\s+(?P<ukind>\w+)\s+(?P<target>\S+)\s+@\s+(?P<sites>.+?)\s*$'
)


def _iter_use_sites(sites: str):
    """Yield (caller|None, line) from a @use sites field."""
    for seg in sites.split():
        if ':' in seg:
            caller, _, nums = seg.partition(':')
        else:
            caller, nums = None, seg
        for n in nums.split(','):
            n = n.strip()
            if n.isdigit():
                yield caller, n


def _bare_name(kind: str, head: str) -> str:
    if kind == "fn":
        m = re.match(r"^(\w+)\(", head)
        return m.group(1) if m else head
    if kind == "api":
        m = re.match(r"^[\w]+[:.](\w+)\(", head)
        return m.group(1) if m else head
    if kind in ("state", "const", "require", "construct"):
        m = re.match(r"^(\w+)", head)
        return m.group(1) if m else head
    return head


def _normalize_kind(k: str) -> str:
    k = k.lower().lstrip("?")
    aliases = {
        "signal": "emits", "signals": "emits",
        "invariants": "invariant", "contracts": "contract", "shapes": "shape",
        "fns": "fn", "functions": "fn",
        "apis": "api",
        "states": "state", "consts": "const", "constants": "const",
        "requires": "require", "import": "require", "imports": "require",
        "constructs": "construct",
        "use": "uses", "usedby": "usedby", "used-by": "usedby", "used_by": "usedby",
    }
    return aliases.get(k, k)


def _entry_kind(raw_kind: str) -> str:
    return raw_kind.lstrip("?")


@mcp.tool(structured_output=False)
def map_query(
    query: Optional[str] = None,
    kind: Optional[str] = None,
    module: Optional[str] = None,
    max_results: int = 60,
) -> str:
    """Structured query over the project's .map semantic outlines.

    Replaces `grep '@fn' map/*.map` and the follow-up read-the-source dance.
    Results carry the originating .lua file:line so you can jump straight
    to the declaration with Read offset/limit.

    Args:
      query: name pattern. Supports `*` and `?` glob wildcards;
             case-insensitive. Matches bare symbol names for structural
             entries (`@fn`, `@api`, `@state`, `@const`, `@require`,
             `@construct`) and full body text for annotations
             (`@invariant`, `@contract`, `@shape`, `@emits`, `@reaper`).
             Omit to return everything matching the other filters.
      kind: filter by entry kind. Accepted (case-insensitive, plurals
            ok): fn, api, state, const, require/import, construct,
            invariant, contract, shape, emits/signal, reaper, deps,
            uses, usedby. `uses` lists a module's outbound edges
            (calls / subs / forwards / requires); `usedby` reverses
            it — every caller of the symbol(s) matched by `query`.
            Omit for any.
      module: restrict to a module by stem (e.g. `trackerManager`) or
              glob (e.g. `tm_*`, `*Manager`). Matches the .map filename
              (without extension).
      max_results: cap (default 60).

    Returns:
      Lines of `<source>.lua:<line>  @kind <head>` for structural entries,
      and `<source>.lua  @kind  <body>` for annotations.
    """
    if not MAP_DIR.exists():
        return f"--- ERROR: {MAP_DIR} not found ---"

    query_rx: Optional[re.Pattern] = None
    if query:
        if "*" in query or "?" in query:
            parts = []
            for ch in query:
                if ch == "*": parts.append(".*")
                elif ch == "?": parts.append(".")
                else: parts.append(re.escape(ch))
            query_rx = re.compile("^" + "".join(parts) + "$", re.IGNORECASE)
        else:
            query_rx = re.compile(re.escape(query), re.IGNORECASE)

    kind_filter = _normalize_kind(kind) if kind else None

    if module:
        if "*" in module or "?" in module:
            module_files = sorted(MAP_DIR.glob(f"{module}.map"))
        else:
            mp = MAP_DIR / f"{module}.map"
            module_files = [mp] if mp.exists() else []
    else:
        module_files = sorted(MAP_DIR.glob("*.map"))

    if not module_files:
        return f"(no .map files matched module={module!r})"

    results: list[str] = []
    truncated = False

    # `uses` / `usedby` walk the `@use` lines, not structural entries / annotations.
    if kind_filter in ('uses', 'usedby'):
        for mp in module_files:
            text = mp.read_text(encoding="utf-8", errors="replace")
            src = mp.stem + ".lua"
            for raw in text.splitlines():
                mu = _USE.match(raw)
                if not mu:
                    continue
                ukind = mu.group("ukind")
                target = mu.group("target")
                if query_rx and not query_rx.search(target):
                    continue
                for caller, n in _iter_use_sites(mu.group("sites")):
                    if len(results) >= max_results:
                        truncated = True
                        break
                    where = f"  (in {caller})" if caller else ""
                    results.append(f"{src}:{n}  @use {ukind} {target}{where}")
                if truncated:
                    break
            if truncated:
                break

        if not results:
            return f"(no matches for kind={kind!r}, query={query!r}, module={module!r})"
        if truncated:
            results.append(f"--- truncated at {max_results}; narrow the query ---")
        if kind_filter == 'usedby':
            results.append("--- note: method calls on runtime receivers (not import/construct/dep aliases) are dropped — recall is incomplete for those ---")
        return "\n".join(results)

    for mp in module_files:
        text = mp.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        src = mp.stem + ".lua"
        if lines:
            h = _MAP_HEADER.match(lines[0])
            if h:
                src = h.group(2)

        for raw in lines:
            if not raw.strip():
                continue

            md = _DECL.match(raw)
            if md:
                if len(results) >= max_results:
                    truncated = True
                    break
                k = md.group("kind")
                head = md.group("head").strip()
                src_line = int(md.group("line"))
                end_line = md.group("end")
                doc = (md.group("doc") or "").strip()

                if kind_filter and kind_filter != k:
                    continue
                if query_rx:
                    bare = _bare_name(k, head)
                    if not query_rx.search(bare):
                        continue

                loc = f"{src}:{src_line}-{end_line}" if end_line else f"{src}:{src_line}"
                tail = f"  {doc}" if doc else ""
                results.append(f"{loc}  @{k} {head}{tail}")
                continue

            ma = _ANN.match(raw)
            if ma:
                raw_kind = ma.group("kind")
                ek = _entry_kind(raw_kind)
                body = ma.group("body").strip()

                if kind_filter and kind_filter != ek:
                    continue
                if query_rx and not query_rx.search(body):
                    continue
                if not kind_filter and not query_rx:
                    continue

                if len(results) >= max_results:
                    truncated = True
                    break
                results.append(f"{src}  @{raw_kind}  {body}")
                continue

        if truncated:
            break

    if not results:
        bits = []
        if query: bits.append(f"query={query!r}")
        if kind: bits.append(f"kind={kind!r}")
        if module: bits.append(f"module={module!r}")
        q = ", ".join(bits) if bits else "<no filters>"
        return f"(no matches for {q})"

    if truncated:
        results.append(f"--- truncated at {max_results}; narrow the query ---")
    return "\n".join(results)


if __name__ == "__main__":
    mcp.run()
