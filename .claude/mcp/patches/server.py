#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Readium apply_patches MCP server.

A batch of search/replace edits, file creates, and deletes across many
paths, gated by interactive review.

**Two review transports.** Default is a loopback HTTP server with a
unified diff and Approve/Reject buttons — coarse, all-or-nothing.

Set `CONTINUUM_REVIEW_EMACS=1` (with a live `emacsclient` server) for
hunk-level review via `continuum-review.el`. Each input edit/create/
delete becomes a separately-tagged block; the user navigates by hunk,
rejects (`k`), folds (`s`), edits narrowed (`e`), comments (`c`), and
submits (`C-c C-c`) with optional further instructions. The response
distinguishes accepted / rejected / edited per index, returns per-hunk
comments and residual diffs for edited hunks, and reports dependency
conflicts when a rejected edit invalidates a later edit's `old`.

Sister servers: readium_docs, readium_tests.
"""

from __future__ import annotations

import difflib
import html
import http.server
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("readium_patches")

PERF_LOG = "/tmp/apply_patches_perf.log"
MAX_BYTES_PER_FILE = 4_000_000
ELISP_PATH = str(Path(__file__).parent / "continuum-review.el")


def _perf_log(line: str) -> None:
    try:
        with open(PERF_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _resolve(raw: str, base: Path) -> str:
    return raw if os.path.isabs(raw) else str(base / raw)


def _read(path: str) -> tuple[Optional[str], Optional[str]]:
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None, "file not found"
    except PermissionError:
        return None, "permission denied"
    if not os.path.isfile(path):
        return None, "not a regular file"
    if st.st_size > MAX_BYTES_PER_FILE:
        return None, f"file too large ({st.st_size} bytes)"
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return None, f"read error: {e}"
    try:
        return data.decode("utf-8"), None
    except UnicodeDecodeError:
        return None, "not utf-8 (binary?)"


# ----- Diff helpers ---------------------------------------------------------

def _unified_diff(old: str, new: str, path: str, n: int) -> list[str]:
    return list(difflib.unified_diff(
        old.splitlines(),
        new.splitlines(),
        fromfile=f"a/{path}",
        tofile=f"b/{path}",
        n=n,
        lineterm="",
    ))


def _hunk_n0(old: str, new: str) -> str:
    """Unified diff with no context, header lines stripped. Used in the
    emacs review buffer: only `@@`, `+`, `-` lines remain, so extracting
    the user's new-side after an edit is unambiguous."""
    lines = _unified_diff(old, new, "x", n=0)
    return "\n".join(ln for ln in lines
                     if not (ln.startswith("--- ") or ln.startswith("+++ ")))


def _extract_new_from_hunk(hunk: str) -> str:
    """Recover the new-side text from a (possibly user-edited) n=0 hunk.

    Tolerates the user stripping `+` prefixes while editing. Only the
    first `@@` block is read. Used for creates (whole file is `+` lines).
    """
    out: list[str] = []
    seen_at = False
    for ln in hunk.splitlines():
        if ln.startswith("@@"):
            if seen_at:
                break
            seen_at = True
            continue
        if ln.startswith("-"):
            continue
        if ln.startswith("+"):
            out.append(ln[1:])
        else:
            out.append(ln)
    return "\n".join(out)


def _extract_hunk_pair(hunk: str) -> tuple[str, str]:
    """Return (old_block, new_block) as line-joined strings from the
    first `@@` block. Used to apply edited edits as line-block
    substitution — sidesteps the substring-replace pitfall where line
    indentation lives outside `old`/`new` but inside the hunk display.

    Unprefixed lines (user stripped the `+` while editing) are treated
    as new-side content.
    """
    olds: list[str] = []
    news: list[str] = []
    seen_at = False
    for ln in hunk.splitlines():
        if ln.startswith("@@"):
            if seen_at:
                break
            seen_at = True
            continue
        if not seen_at:
            continue
        if ln.startswith("-"):
            olds.append(ln[1:])
        elif ln.startswith("+"):
            news.append(ln[1:])
        else:
            news.append(ln)
    return "\n".join(olds), "\n".join(news)


# ----- Browser rendering (fallback transport) -------------------------------

_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>apply_patches — {n_files} file(s)</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         background: #0d1117; color: #c9d1d9; margin: 0; }
  header { position: sticky; top: 0; background: #161b22; padding: 12px 20px;
           border-bottom: 1px solid #30363d; z-index: 10; }
  header h1 { font-size: 14px; margin: 0; font-weight: 600; }
  header .summary { color: #8b949e; font-size: 12px; margin-top: 4px;
                    font-family: ui-monospace, SFMono-Regular, monospace; }
  main { max-width: 1100px; margin: 0 auto; padding: 20px; padding-bottom: 220px; }
  .file { margin-bottom: 24px; border: 1px solid #30363d; border-radius: 6px;
          overflow: hidden; background: #0d1117; }
  .file h2 { font-size: 12px; font-weight: 600; padding: 8px 12px;
             background: #161b22; margin: 0; border-bottom: 1px solid #30363d;
             font-family: ui-monospace, SFMono-Regular, monospace;
             display: flex; gap: 8px; align-items: center; }
  .badge { font-size: 10px; padding: 2px 6px; border-radius: 3px;
           font-family: -apple-system, sans-serif; font-weight: 600;
           text-transform: uppercase; letter-spacing: 0.5px; }
  .badge.create { background: #1f6feb; color: white; }
  .badge.delete { background: #da3633; color: white; }
  pre { margin: 0; font-family: ui-monospace, SFMono-Regular, monospace;
        font-size: 14px; line-height: 1.2; overflow-x: auto; }
  .line { display: block; padding: 0 12px; white-space: pre-wrap;
          overflow-wrap: anywhere; }
  .line.add { background: rgba(46, 160, 67, 0.15); color: #aff5b4; }
  .line.del { background: rgba(248, 81, 73, 0.15); color: #ffdcd7; }
  .line.hunk { color: #79c0ff; padding-top: 4px; padding-bottom: 4px;
               border-top: 1px solid #21262d; border-bottom: 1px solid #21262d;
               margin: 2px 0; }
  .line.ctx { color: #c9d1d9; }
  footer { position: fixed; bottom: 0; left: 0; right: 0;
           background: #161b22; border-top: 1px solid #30363d;
           padding: 12px 20px; }
  .footer-inner { max-width: 1100px; margin: 0 auto;
                  display: flex; gap: 12px; align-items: flex-end; }
  textarea { flex: 1; background: #0d1117; color: #c9d1d9;
             border: 1px solid #30363d; border-radius: 6px; padding: 8px;
             font-family: inherit; font-size: 13px;
             resize: vertical; min-height: 60px; max-height: 160px; }
  textarea:focus { outline: none; border-color: #58a6ff; }
  button { padding: 10px 22px; border-radius: 6px; border: 1px solid;
           cursor: pointer; font-size: 14px; font-weight: 600; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  .approve { background: #238636; border-color: #238636; color: white; }
  .approve:hover:not(:disabled) { background: #2ea043; }
  .reject { background: #21262d; border-color: #30363d; color: #c9d1d9; }
  .reject:hover:not(:disabled) { background: #30363d; }
  #status { padding: 40px 20px; text-align: center; color: #8b949e;
            font-size: 14px; display: none; }
  .empty { padding: 40px; text-align: center; color: #8b949e; }
</style>
</head>
<body>
<header>
  <h1>apply_patches preview</h1>
  <div class="summary">{summary_html}</div>
</header>
<main id="diffs">
{diffs_html}
</main>
<div id="status"></div>
<footer>
  <div class="footer-inner">
    <textarea id="comment" placeholder="optional comment for Claude (sent back regardless of approve/reject)" autofocus></textarea>
    <button class="reject" id="reject-btn" onclick="decide('reject')">Reject</button>
    <button class="approve" id="approve-btn" onclick="decide('approve')">Approve</button>
  </div>
</footer>
<script>
async function decide(action) {
  const comment = document.getElementById('comment').value;
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  document.getElementById('diffs').style.display = 'none';
  document.querySelector('footer').style.display = 'none';
  const status = document.getElementById('status');
  status.style.display = 'block';
  status.textContent = action === 'approve' ? 'Applying...' : 'Aborting...';
  try {
    await fetch('/' + action, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({comment})
    });
  } catch (e) {
    status.textContent = 'Error: ' + e.message;
    return;
  }
  status.textContent = 'Done. You can close this tab.';
  setTimeout(() => { try { window.close(); } catch (e) {} }, 200);
}
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
    e.preventDefault();
    decide('approve');
  }
});
</script>
</body>
</html>
"""


def _diff_html(old: str, new: str, path: str, kind: str = "edit") -> tuple[str, int]:
    lines = _unified_diff(old, new, path, n=3)
    if not lines:
        return "", 0
    n_hunks = 0
    parts = ['<div class="file"><h2>', html.escape(path)]
    if kind == "create":
        parts.append(' <span class="badge create">create</span>')
    elif kind == "delete":
        parts.append(' <span class="badge delete">delete</span>')
    parts.append('</h2><pre>')
    for line in lines:
        if line.startswith("--- ") or line.startswith("+++ "):
            continue
        if line.startswith("@@"):
            cls = "hunk"
            n_hunks += 1
        elif line.startswith("+"):
            cls = "add"
        elif line.startswith("-"):
            cls = "del"
        else:
            cls = "ctx"
        parts.append(f'<span class="line {cls}">{html.escape(line)}</span>\n')
    parts.append('</pre></div>')
    return "".join(parts), n_hunks


class _ApprovalState:
    page_html: str = ""
    decision: Optional[tuple[bool, str]] = None
    event: Optional[threading.Event] = None


class _ApprovalHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass

    def do_GET(self):
        if self.path == "/":
            body = _ApprovalState.page_html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        approved = self.path == "/approve"
        rejected = self.path == "/reject"
        if not (approved or rejected):
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8") if length else "{}"
        try:
            data = json.loads(raw)
            comment = str(data.get("comment", ""))
        except Exception:
            comment = ""
        _ApprovalState.decision = (approved, comment)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')
        if _ApprovalState.event:
            _ApprovalState.event.set()


def _gate_with_browser(diffs_html: str, summary: str, n_files: int) -> tuple[bool, str]:
    page = (
        _HTML_TEMPLATE
        .replace("{n_files}", str(n_files))
        .replace("{summary_html}", html.escape(summary).replace("\n", "<br>"))
        .replace("{diffs_html}", diffs_html or '<div class="empty">(no textual changes)</div>')
    )
    _ApprovalState.page_html = page
    _ApprovalState.decision = None
    _ApprovalState.event = threading.Event()

    server = http.server.HTTPServer(("127.0.0.1", 0), _ApprovalHandler)
    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/"

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass

    _ApprovalState.event.wait()
    server.shutdown()
    thread.join(timeout=2)

    return _ApprovalState.decision or (False, "(no decision)")


# ----- Emacs transport ------------------------------------------------------

def _emacs_cmd_prefix() -> list[str]:
    prefix = ["emacsclient"]
    sock = os.environ.get("EMACS_SOCKET_NAME")
    if sock:
        prefix += ["-s", sock]
    return prefix


def _emacs_available() -> bool:
    if os.environ.get("CONTINUUM_REVIEW_EMACS") != "1":
        return False
    if not shutil.which("emacsclient"):
        return False
    try:
        r = subprocess.run(_emacs_cmd_prefix() + ["-e", "t"],
                           capture_output=True, timeout=3, text=True)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _emacs_ensure_loaded() -> bool:
    # Always reload: the elisp lives next to this file and we want
    # edits to take effect on the next apply_patches without forcing
    # the user to restart Emacs.
    form = f'(load "{ELISP_PATH}" nil t)'
    try:
        r = subprocess.run(_emacs_cmd_prefix() + ["-e", form],
                           capture_output=True, timeout=10, text=True)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _build_review_buffer(edit_recs: list[dict], create_recs: list[dict],
                         delete_recs: list[dict]) -> str:
    parts = [
        f"# apply_patches — {len(edit_recs)} edit(s), "
        f"{len(create_recs)} create(s), {len(delete_recs)} delete(s)\n"
        "#\n"
        "# Keys: n/p navigate · k reject · s fold · e edit · c comment\n"
        "#       C-c C-c submit · C-c C-k abort\n"
        "# " + "-" * 68 + "\n\n",
    ]
    for r in edit_recs:
        parts.append(f"### edit {r['idx']} · {r['path']}\n{r['hunk']}\n\n")
    for r in create_recs:
        parts.append(f"### create {r['idx']} · {r['path']}\n{r['hunk']}\n\n")
    for r in delete_recs:
        parts.append(f"### delete {r['idx']} · {r['path']}\n{r['hunk']}\n\n")
    return "".join(parts)


def _gate_with_emacs(edit_recs: list[dict], create_recs: list[dict],
                     delete_recs: list[dict]
                     ) -> Optional[tuple[bool, str, list[dict]]]:
    """Open the review buffer in Emacs; block on response.

    Returns (aborted, instructions, blocks) or None if emacs is
    unavailable or the call failed (caller falls back to browser)."""
    if not _emacs_available() or not _emacs_ensure_loaded():
        return None

    req_fd, req_path = tempfile.mkstemp(prefix="continuum_review_req_", suffix=".json")
    resp_fd, resp_path = tempfile.mkstemp(prefix="continuum_review_resp_", suffix=".json")
    os.close(req_fd)
    os.close(resp_fd)
    try:
        os.unlink(resp_path)
    except OSError:
        pass

    buffer_text = _build_review_buffer(edit_recs, create_recs, delete_recs)
    with open(req_path, "w", encoding="utf-8") as f:
        json.dump({"buffer": buffer_text}, f)

    def _q(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    form = f'(continuum-review-start "{_q(req_path)}" "{_q(resp_path)}")'
    try:
        subprocess.run(_emacs_cmd_prefix() + ["--no-wait", "-e", form],
                       capture_output=True, timeout=5, check=True)
    except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
        for p in (req_path,):
            try: os.unlink(p)
            except OSError: pass
        return None

    deadline = time.time() + 3600.0
    while time.time() < deadline:
        if os.path.exists(resp_path):
            try:
                with open(resp_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, json.JSONDecodeError):
                time.sleep(0.1)
                continue
            for p in (req_path, resp_path):
                try: os.unlink(p)
                except OSError: pass
            return (
                bool(data.get("aborted")),
                str(data.get("instructions", "")),
                list(data.get("blocks", [])),
            )
        time.sleep(0.2)

    for p in (req_path,):
        try: os.unlink(p)
        except OSError: pass
    return None


# ----- Per-edit decision application ----------------------------------------

def _apply_decisions(edit_recs: list[dict], create_recs: list[dict],
                     delete_recs: list[dict], blocks: list[dict]
                     ) -> tuple[dict, dict, dict, list[str]]:
    """Walk records against the elisp response.

    Returns:
      decisions: {(kind, idx) -> {action, comment, user_new?, staged_new?}}
        action ∈ {accept, edit, reject}
      file_content: {path -> final content for paths with edits applied}
      create_content: {path -> final content for accepted creates}
      delete_paths: [path, ...] for accepted deletes
    """
    by_key = {(b.get("kind"), int(b.get("index", -1))): b for b in blocks}
    decisions: dict[tuple[str, int], dict] = {}
    file_content: dict[str, str] = {}

    for r in edit_recs:
        key = ("edit", r["idx"])
        block = by_key.get(key)
        comment = (block or {}).get("comment", "") or ""
        if block is None or bool(block.get("rejected")):
            decisions[key] = {"action": "reject", "comment": comment}
            continue
        edited = bool(block.get("edited"))
        cur = file_content.get(r["path"], r["before"])
        if edited:
            # Line-block substitution: replace the hunk's `-` block with
            # the (possibly edited) `+` block. Avoids the substring-
            # replace pitfall where line indentation sits outside
            # `old`/`new` but inside the hunk display.
            old_block, new_block = _extract_hunk_pair(block.get("hunk", ""))
            if old_block not in cur:
                decisions[key] = {
                    "action": "reject", "comment": comment,
                    "conflict": "edited hunk's `-` block not found in current file",
                }
                continue
            cur = (cur.replace(old_block, new_block)
                   if r["replace_all"]
                   else cur.replace(old_block, new_block, 1))
            file_content[r["path"]] = cur
            decisions[key] = {
                "action": "edit",
                "comment": comment,
                "user_new": new_block,
                "staged_new": r["new"],
            }
        else:
            if r["old"] not in cur:
                decisions[key] = {
                    "action": "reject", "comment": comment,
                    "conflict": "old not found — likely depends on a rejected earlier edit",
                }
                continue
            cur = (cur.replace(r["old"], r["new"])
                   if r["replace_all"]
                   else cur.replace(r["old"], r["new"], 1))
            file_content[r["path"]] = cur
            decisions[key] = {
                "action": "accept",
                "comment": comment,
                "user_new": None,
                "staged_new": r["new"],
            }

    create_content: dict[str, str] = {}
    for r in create_recs:
        key = ("create", r["idx"])
        block = by_key.get(key)
        comment = (block or {}).get("comment", "") or ""
        if block is None or bool(block.get("rejected")):
            decisions[key] = {"action": "reject", "comment": comment}
            continue
        edited = bool(block.get("edited"))
        content = (_extract_new_from_hunk(block.get("hunk", ""))
                   if edited else r["content"])
        create_content[r["path"]] = content
        decisions[key] = {
            "action": "edit" if edited else "accept",
            "comment": comment,
            "user_new": content if edited else None,
            "staged_new": r["content"],
        }

    delete_paths: list[str] = []
    for r in delete_recs:
        key = ("delete", r["idx"])
        block = by_key.get(key)
        comment = (block or {}).get("comment", "") or ""
        if block is None or bool(block.get("rejected")):
            decisions[key] = {"action": "reject", "comment": comment}
            continue
        if bool(block.get("edited")):
            decisions[key] = {
                "action": "reject", "comment": comment,
                "conflict": "delete cannot be edited; treated as rejected",
            }
            continue
        delete_paths.append(r["path"])
        decisions[key] = {"action": "accept", "comment": comment}

    return decisions, file_content, create_content, delete_paths


def _format_review_result(decisions: dict, instructions: str) -> str:
    """Render the per-edit verdict back to Claude.

    User comments are surfaced as `feedback:` blocks under each tagged
    item, regardless of accept/reject/edit verdict — they are user
    directives to Claude, not metadata, and need to read that way.
    """
    accepted:  list[tuple[str, int, dict]] = []
    rejected:  list[tuple[str, int, dict]] = []
    edited:    list[tuple[str, int, dict]] = []
    conflicts: list[tuple[str, int, dict]] = []
    for (kind, idx), d in decisions.items():
        if d.get("conflict"):
            conflicts.append((kind, idx, d))
            continue
        bucket = {"accept": accepted, "reject": rejected, "edit": edited}.get(d["action"])
        if bucket is not None:
            bucket.append((kind, idx, d))

    def _emit_feedback(out: list[str], d: dict, indent: str) -> None:
        c = (d.get("comment") or "").strip()
        if not c:
            return
        out.append(f"{indent}feedback:")
        for ln in c.splitlines():
            out.append(f"{indent}  {ln}")

    out: list[str] = ["review:"]
    if accepted:
        out.append(f"  accepted ({len(accepted)}):")
        for kind, idx, d in accepted:
            out.append(f"    {kind}{idx}")
            _emit_feedback(out, d, "      ")
    if rejected:
        out.append(f"  rejected ({len(rejected)}):")
        for kind, idx, d in rejected:
            out.append(f"    {kind}{idx}")
            _emit_feedback(out, d, "      ")
    if edited:
        out.append(f"  edited ({len(edited)}):")
        for kind, idx, d in edited:
            tag = f"{kind}{idx}"
            residual = "\n".join(_unified_diff(
                d.get("staged_new") or "",
                d.get("user_new") or "",
                f"{tag} (claude → user)",
                n=3,
            ))
            out.append(f"    {tag}:")
            for ln in residual.splitlines():
                out.append(f"      {ln}")
            _emit_feedback(out, d, "      ")
    if conflicts:
        out.append(f"  conflicts ({len(conflicts)}):")
        for kind, idx, d in conflicts:
            out.append(f"    {kind}{idx}: {d.get('conflict','')}")
            _emit_feedback(out, d, "      ")
    if instructions.strip():
        out.append("instructions: |")
        for ln in instructions.splitlines():
            out.append(f"  {ln}")
    return "\n".join(out)


# ----- Main tool ------------------------------------------------------------


@mcp.tool(structured_output=False)
def apply_patches(
    edits: Optional[list[dict]] = None,
    creates: Optional[list[dict]] = None,
    deletes: Optional[list[str]] = None,
    cwd: Optional[str] = None,
) -> str:
    """Apply a batch of edits, file creations, and deletions, gated by
    interactive review.

    Two transports are supported. Default: browser tab with Approve/
    Reject. With `CONTINUUM_REVIEW_EMACS=1` and a live emacsclient
    server: hunk-level review in Emacs via `continuum-review.el`. In
    that mode the user can reject, edit, or comment on each input
    edit/create/delete individually, and the response reports per-index
    verdicts plus residual diffs for edited hunks.

    Same search/replace semantics as the built-in Edit tool: each edit's
    `old` must appear in the (current, post-prior-edits) file content
    exactly once unless `replace_all` is true. All operations are
    validated and staged in memory first; if anything fails the call
    ABORTs and the filesystem is untouched.

    Args:
      edits: list of {path, old, new, replace_all?}.
      creates: list of {path, content, overwrite?}.
      deletes: list of paths.
      cwd: working directory for relative paths.
    """
    t0 = time.perf_counter()
    _perf_log(
        f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] received "
        f"edits={len(edits or [])} creates={len(creates or [])} deletes={len(deletes or [])}"
    )

    edits = edits or []
    creates = creates or []
    deletes = deletes or []
    if not (edits or creates or deletes):
        return "(no operations requested)"

    base = Path(cwd) if cwd else Path.cwd()
    errors: list[str] = []

    edit_paths = {_resolve(e["path"], base) for e in edits
                  if isinstance(e, dict) and "path" in e}
    create_paths = {_resolve(c["path"], base) for c in creates
                    if isinstance(c, dict) and "path" in c}
    delete_paths = {_resolve(p, base) for p in deletes if isinstance(p, str)}

    for p in edit_paths & create_paths:
        errors.append(f"collision: {p} appears in both edits and creates")
    for p in edit_paths & delete_paths:
        errors.append(f"collision: {p} appears in both edits and deletes")
    for p in create_paths & delete_paths:
        errors.append(f"collision: {p} appears in both creates and deletes")
    if errors:
        return "ABORT — filesystem untouched\n" + "\n".join(f"  • {e}" for e in errors)

    # ---- Stage edits: per-edit records, tracking running per-path content ----
    _t = time.perf_counter()
    edit_recs: list[dict] = []
    file_originals: dict[str, str] = {}
    file_running: dict[str, str] = {}

    for i, e in enumerate(edits):
        if not isinstance(e, dict) or not all(k in e for k in ("path", "old", "new")):
            errors.append(f"edits[{i}]: missing path/old/new")
            continue
        path = _resolve(e["path"], base)
        if path not in file_originals:
            content, err = _read(path)
            if err:
                errors.append(f"{path}: {err}")
                file_originals[path] = ""
                file_running[path] = ""
                continue
            file_originals[path] = content
            file_running[path] = content
        old, new = e["old"], e["new"]
        replace_all = bool(e.get("replace_all", False))
        if old == new:
            errors.append(f"edits[{i}]: edit old == new (no-op)")
            continue
        cur = file_running[path]
        count = cur.count(old)
        if count == 0:
            errors.append(f"edits[{i}] {path}: old not found")
            continue
        if count > 1 and not replace_all:
            errors.append(f"edits[{i}] {path}: old not unique ({count}) — use replace_all or expand context")
            continue
        before = cur
        after = (cur.replace(old, new) if replace_all
                 else cur.replace(old, new, 1))
        edit_recs.append({
            "idx": i + 1,
            "path": path,
            "old": old,
            "new": new,
            "replace_all": replace_all,
            "before": before,
            "after": after,
            "hunk": _hunk_n0(before, after),
        })
        file_running[path] = after

    # ---- Stage creates ----
    create_recs: list[dict] = []
    for i, c in enumerate(creates):
        if not isinstance(c, dict) or "path" not in c or "content" not in c:
            errors.append(f"creates[{i}]: missing path/content")
            continue
        path = _resolve(c["path"], base)
        overwrite = bool(c.get("overwrite", False))
        if os.path.exists(path) and not overwrite:
            errors.append(f"{path}: already exists (set overwrite=true to replace)")
            continue
        existing = ""
        if os.path.exists(path):
            existing, _ = _read(path)
            existing = existing or ""
        create_recs.append({
            "idx": i + 1,
            "path": path,
            "content": c["content"],
            "overwrite": overwrite,
            "hunk": _hunk_n0(existing, c["content"]),
        })

    # ---- Validate deletes ----
    delete_recs: list[dict] = []
    for i, p in enumerate(deletes):
        if not isinstance(p, str):
            errors.append(f"deletes[{i}]: non-string entry {p!r}")
            continue
        path = _resolve(p, base)
        if not os.path.exists(path):
            errors.append(f"{path}: cannot delete, does not exist")
            continue
        if not os.path.isfile(path):
            errors.append(f"{path}: cannot delete, not a regular file")
            continue
        body, _err = _read(path)
        delete_recs.append({
            "idx": i + 1,
            "path": path,
            "content": body or "",
            "hunk": _hunk_n0(body or "", ""),
        })

    if errors:
        return "ABORT — filesystem untouched\n" + "\n".join(f"  • {e}" for e in errors)

    perf = {"stage": time.perf_counter() - _t}

    # ---- Summary line ----
    summary_lines: list[str] = []
    if edit_recs:
        summary_lines.append(f"edits: {len(edit_recs)} on {len(set(r['path'] for r in edit_recs))} file(s)")
    if create_recs:
        summary_lines.append(f"creates: {len(create_recs)}")
    if delete_recs:
        summary_lines.append(f"deletes: {len(delete_recs)}")
    summary = "\n".join(summary_lines) if summary_lines else "(no-op)"

    # ---- Try Emacs transport first ----
    _t = time.perf_counter()
    emacs_result = _gate_with_emacs(edit_recs, create_recs, delete_recs)
    perf["gate"] = time.perf_counter() - _t

    if emacs_result is not None:
        aborted, instructions, blocks = emacs_result
        if aborted:
            _perf_log(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] emacs aborted "
                      f"total={time.perf_counter()-t0:.3f}s")
            msg = "ABORTED by user"
            if instructions.strip():
                msg += f"\nreason: {instructions.strip()}"
            msg += "\n(no files written)"
            return msg
        decisions, file_content, create_content, accept_deletes = \
            _apply_decisions(edit_recs, create_recs, delete_recs, blocks)
        _t = time.perf_counter()
        written: list[str] = []
        try:
            for path, content in file_content.items():
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                written.append(path)
            for path, content in create_content.items():
                os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                written.append(path)
            for path in accept_deletes:
                os.remove(path)
        except OSError as e:
            return (f"PARTIAL FAILURE during flush: {e}\n"
                    f"wrote {len(written)} file(s) before failure:\n"
                    + "\n".join(f"  • {p}" for p in written))
        perf["flush"] = time.perf_counter() - _t
        perf["total"] = time.perf_counter() - t0
        _perf_log(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] emacs applied "
                  f"e={len(edit_recs)} c={len(create_recs)} d={len(delete_recs)} "
                  f"stage={perf['stage']:.3f}s gate={perf['gate']:.3f}s "
                  f"flush={perf['flush']:.3f}s total={perf['total']:.3f}s")
        return _format_review_result(decisions, instructions)

    # ---- Browser fallback (coarse all-or-nothing) ----
    _t = time.perf_counter()
    diff_chunks: list[str] = []
    n_hunks = 0
    seen_paths: set[str] = set()
    for path in [r["path"] for r in edit_recs]:
        if path in seen_paths: continue
        seen_paths.add(path)
        d, h = _diff_html(file_originals[path], file_running[path], path, kind="edit")
        if d:
            diff_chunks.append(d); n_hunks += h
    for r in create_recs:
        d, h = _diff_html("", r["content"], r["path"], kind="create")
        if d:
            diff_chunks.append(d); n_hunks += h
    for r in delete_recs:
        d, h = _diff_html(r["content"], "", r["path"], kind="delete")
        if d:
            diff_chunks.append(d); n_hunks += h
    n_files = len(seen_paths) + len(create_recs) + len(delete_recs)
    perf["diff_html"] = time.perf_counter() - _t

    _t = time.perf_counter()
    approved, comment = _gate_with_browser("".join(diff_chunks), summary, n_files)
    perf["wait"] = time.perf_counter() - _t

    if not approved:
        perf["total"] = time.perf_counter() - t0
        _perf_log(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] browser rejected "
                  f"files={n_files} hunks={n_hunks} total={perf['total']:.3f}s")
        msg = "REJECTED by user"
        if comment.strip():
            msg += f"\nuser comment: {comment.strip()}"
        msg += "\n(no files written)"
        return msg

    _t = time.perf_counter()
    written: list[str] = []
    try:
        for path in seen_paths:
            with open(path, "w", encoding="utf-8") as f:
                f.write(file_running[path])
            written.append(path)
        for r in create_recs:
            os.makedirs(os.path.dirname(r["path"]) or ".", exist_ok=True)
            with open(r["path"], "w", encoding="utf-8") as f:
                f.write(r["content"])
            written.append(r["path"])
        for r in delete_recs:
            os.remove(r["path"])
    except OSError as e:
        return (f"PARTIAL FAILURE during flush: {e}\n"
                f"wrote {len(written)} file(s) before failure:\n"
                + "\n".join(f"  • {p}" for p in written))

    perf["flush"] = time.perf_counter() - _t
    perf["total"] = time.perf_counter() - t0
    _perf_log(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] browser applied "
              f"files={n_files} hunks={n_hunks} "
              f"stage={perf['stage']:.3f}s diff_html={perf['diff_html']:.3f}s "
              f"wait={perf['wait']:.3f}s flush={perf['flush']:.3f}s "
              f"total={perf['total']:.3f}s")

    msg = f"applied:\n{summary}"
    if comment.strip():
        msg = f"applied (user comment: {comment.strip()!r}):\n{summary}"
    return msg


if __name__ == "__main__":
    mcp.run()
