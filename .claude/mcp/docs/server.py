#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]
# ///
"""REAPER framework-docs MCP server.

One tool: reaper_doc_lookup — parse the bundled REAPER + ReaImGui HTML and
return clean prose entries by function/constant name.

Formerly readium_docs; map_query moved to the sister `continuum_map` server.
Other sisters: continuum_tests (lua_test_run), reaper (reaper_eval). Batched
writes are handled by the global `patches` server (mcp__patches__apply_patches).
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

# pydantic titles every field and model after the name it was derived from
# ('Kind' for kind, '<tool>Arguments' for the model), which tool schemas then
# carry into always-loaded context. Drop them at the one point every tool's
# arg model shares.
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
REASCRIPT_HTML = PROJECT_ROOT / "docs" / "REAPER API functions.html"
IMGUI_HTML = PROJECT_ROOT / "docs" / "reaper_imgui_doc.html"

mcp = FastMCP("reaper_docs")


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


# Old glob habits produce valid-but-narrower regex: 'same*pitch' quantifies
# the literal 'e'. Advise rather than block.
_LITERAL_QUANT = re.compile(r'(?<!\\)\w\*')


def _glob_smell(pat: Optional[str]) -> Optional[str]:
    m = _LITERAL_QUANT.search(pat) if pat else None
    if m:
        return (f"--- note: regex reads {m.group(0)!r} as a quantified "
                "literal; for a glob-style wildcard use '.*' ---")
    return None


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
      name: function or constant name. Case-insensitive. A plain name
            looks up exactly; a name containing regex metacharacters is
            a regex (substring-matched — anchor with ^$ as needed) and
            returns a one-line index (name + Lua signature) instead of
            full prose, capped at `max_matches`.
      kind: "auto" (default) searches both ReaScript and ReaImGui;
            "reascript" or "imgui" restrict to one. ReaScript names are
            CamelCase like `GetMediaItemTrack`. ReaImGui names omit the
            `ImGui_` prefix in the docs (e.g. `Begin`, `Button`).
      max_matches: cap on wildcard match results (default 30).

    Returns:
      Cleanly-formatted entries (one per match) or an "(no match)" line.
    """
    is_pattern = re.escape(name) != name
    rx = None
    if is_pattern:
        try:
            rx = re.compile(name, re.IGNORECASE)
        except re.error as exc:
            return (f"--- ERROR: {name!r} is not valid regex ({exc}); "
                    "a plain name looks up exactly ---")

    blocks: list[str] = []
    truncated = False

    if kind in ("auto", "reascript"):
        try:
            entries, text = _load_reascript()
        except FileNotFoundError:
            blocks.append(f"--- ERROR: missing {REASCRIPT_HTML} ---")
        else:
            if is_pattern:
                hits = [(n, s, e) for (n, s, e) in entries if rx.search(n)]
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
                hits = [n for n in names if rx.search(n)]
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

    note = _glob_smell(name)
    if not blocks:
        suffix = "" if kind == "auto" else f" (kind={kind})"
        miss = f"(no match for {name!r}{suffix})"
        return f"{miss}\n{note}" if note else miss
    if truncated:
        blocks.append(f"--- truncated at {max_matches} matches; narrow the pattern ---")
    if note:
        blocks.append(note)
    return "\n\n".join(blocks)


if __name__ == "__main__":
    mcp.run()
