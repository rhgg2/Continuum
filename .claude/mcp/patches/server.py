#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Readium apply_patches MCP server.

Atomic batch of search/replace edits, file creates, and deletes across
many paths. Either every operation validates and is flushed, or nothing
is written.

**Workflow:** every call opens a browser at a loopback HTTP server with
a unified diff and Approve/Reject buttons (plus an optional comment
field). The tool blocks until the user clicks. No dry_run flag — single
round-trip per batch, no token doubling. The user's decision (and any
comment) comes back to Claude as the tool result.

Sister servers: readium_docs, readium_tests.
"""

from __future__ import annotations

import difflib
import html
import http.server
import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("readium_patches")

PERF_LOG = "/tmp/apply_patches_perf.log"
MAX_BYTES_PER_FILE = 4_000_000


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


# ----- HTML rendering -------------------------------------------------------

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
        font-size: 12px; line-height: 1.5; overflow-x: auto; }
  .line { display: block; padding: 0 12px; white-space: pre; min-height: 1.5em; }
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
  // Best-effort auto-close. Browsers usually only allow window.close()
  // for tabs JS opened, so this often fails silently — the message above
  // is the fallback.
  setTimeout(() => { try { window.close(); } catch (e) {} }, 200);
}
// Cmd+Enter to approve
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
    """Return (html, n_hunks). Empty html if no textual change."""
    lines = list(difflib.unified_diff(
        old.splitlines(),
        new.splitlines(),
        fromfile=f"a/{path}",
        tofile=f"b/{path}",
        n=3,
        lineterm="",
    ))
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
        # Skip the file-header lines — the h2 already shows the path.
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


# ----- Browser-gated approval -----------------------------------------------


class _ApprovalState:
    """Shared state between the HTTP handler and the main thread."""
    page_html: str = ""
    decision: Optional[tuple[bool, str]] = None
    event: Optional[threading.Event] = None


class _ApprovalHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass  # Don't pollute stderr with request logs.

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
    """Open a browser, block until user clicks Approve or Reject. Returns
    (approved, comment)."""
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

    # Best-effort browser launch. If `open` fails, the URL is still printed
    # to the controlling TTY so the user can paste it manually.
    try:
        subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass
    try:
        with open("/dev/tty", "w") as tty:
            tty.write(f"\napply_patches: review at {url}\n")
            tty.flush()
    except OSError:
        pass

    _ApprovalState.event.wait()
    server.shutdown()
    thread.join(timeout=2)

    return _ApprovalState.decision or (False, "(no decision)")


# ----- Main tool ------------------------------------------------------------


@mcp.tool(structured_output=False)
def apply_patches(
    edits: Optional[list[dict]] = None,
    creates: Optional[list[dict]] = None,
    deletes: Optional[list[str]] = None,
    cwd: Optional[str] = None,
) -> str:
    """Apply a batch of edits, file creations, and deletions atomically,
    gated by browser approval.

    **Workflow:** the call validates everything, then opens a browser tab
    showing a unified diff with Approve/Reject buttons and an optional
    comment field. The tool blocks until you click. On Approve, the
    filesystem is written; on Reject, nothing is written. Either way the
    user's comment (if any) comes back to Claude in the result string.

    Same search/replace semantics as the built-in Edit tool: each edit's
    `old` must appear in the (current, post-prior-edits) file content
    exactly once unless `replace_all` is true. All operations are validated
    and staged in memory first; if anything fails the call ABORTs and the
    filesystem is untouched.

    Args:
      edits: list of {path: str, old: str, new: str, replace_all?: bool}.
             Multiple edits to the same path are applied in given order.
      creates: list of {path: str, content: str, overwrite?: bool}. Errors
               if path exists unless overwrite=true. Parent dirs auto-mkdir.
      deletes: list of paths to delete. Errors if path missing.
      cwd: working directory for relative paths (default: process CWD).

    Returns:
      On approve: `applied: <summary>` (with comment appended if given).
      On reject: `REJECTED by user` (with comment appended if given).
      On validation/policy failure: `ABORT` header followed by errors.
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

    perf: dict[str, float] = {}

    base = Path(cwd) if cwd else Path.cwd()
    errors: list[str] = []

    edit_paths = {_resolve(e["path"], base) for e in edits if isinstance(e, dict) and "path" in e}
    create_paths = {_resolve(c["path"], base) for c in creates if isinstance(c, dict) and "path" in c}
    delete_paths = {_resolve(p, base) for p in deletes if isinstance(p, str)}

    for p in edit_paths & create_paths:
        errors.append(f"collision: {p} appears in both edits and creates")
    for p in edit_paths & delete_paths:
        errors.append(f"collision: {p} appears in both edits and deletes")
    for p in create_paths & delete_paths:
        errors.append(f"collision: {p} appears in both creates and deletes")

    if errors:
        return "ABORT — filesystem untouched\n" + "\n".join(f"  • {e}" for e in errors)

    # ---- Stage edits ----
    by_path: dict[str, list[dict]] = {}
    for i, e in enumerate(edits):
        if not isinstance(e, dict) or not all(k in e for k in ("path", "old", "new")):
            errors.append(f"edits[{i}]: missing path/old/new")
            continue
        by_path.setdefault(_resolve(e["path"], base), []).append(e)

    staged_edits: dict[str, str] = {}
    edit_originals: dict[str, str] = {}
    edit_summaries: list[str] = []
    _t = time.perf_counter()
    for path, group in by_path.items():
        content, err = _read(path)
        if err:
            errors.append(f"{path}: {err}")
            continue
        edit_originals[path] = content
        cur = content
        ops_done: list[str] = []
        for j, e in enumerate(group):
            old = e["old"]
            new = e["new"]
            replace_all = bool(e.get("replace_all", False))
            if old == new:
                errors.append(f"{path}: edit #{j+1} old == new (no-op)")
                continue
            if replace_all:
                if old not in cur:
                    errors.append(f"{path}: edit #{j+1} old not found")
                    continue
                count = cur.count(old)
                cur = cur.replace(old, new)
                ops_done.append(f"replaced {count}× edit#{j+1}")
            else:
                count = cur.count(old)
                if count == 0:
                    errors.append(f"{path}: edit #{j+1} old not found")
                    continue
                if count > 1:
                    errors.append(f"{path}: edit #{j+1} old not unique ({count} occurrences) — use replace_all or expand context")
                    continue
                cur = cur.replace(old, new, 1)
                ops_done.append(f"edit#{j+1}")
        staged_edits[path] = cur
        if ops_done:
            edit_summaries.append(f"  {path}: {', '.join(ops_done)}")

    perf["stage_edits"] = time.perf_counter() - _t

    # ---- Stage creates ----
    staged_creates: dict[str, str] = {}
    create_summaries: list[str] = []
    for i, c in enumerate(creates):
        if not isinstance(c, dict) or "path" not in c or "content" not in c:
            errors.append(f"creates[{i}]: missing path/content")
            continue
        path = _resolve(c["path"], base)
        overwrite = bool(c.get("overwrite", False))
        if os.path.exists(path) and not overwrite:
            errors.append(f"{path}: already exists (set overwrite=true to replace)")
            continue
        staged_creates[path] = c["content"]
        create_summaries.append(f"  {path}: create ({len(c['content'])} bytes)")

    # ---- Validate deletes ----
    valid_deletes: list[str] = []
    delete_originals: dict[str, str] = {}
    delete_summaries: list[str] = []
    for p in deletes:
        if not isinstance(p, str):
            errors.append(f"deletes: non-string entry {p!r}")
            continue
        path = _resolve(p, base)
        if not os.path.exists(path):
            errors.append(f"{path}: cannot delete, does not exist")
            continue
        if not os.path.isfile(path):
            errors.append(f"{path}: cannot delete, not a regular file")
            continue
        valid_deletes.append(path)
        body, _err = _read(path)
        delete_originals[path] = body or ""
        delete_summaries.append(f"  {path}: delete")

    if errors:
        return "ABORT — filesystem untouched\n" + "\n".join(f"  • {e}" for e in errors)

    # ---- Build summary + diff HTML ----
    summary_lines: list[str] = []
    if edit_summaries:
        summary_lines.append(f"edits ({len(by_path)} file(s)):")
        summary_lines.extend(edit_summaries)
    if create_summaries:
        summary_lines.append(f"creates ({len(staged_creates)}):")
        summary_lines.extend(create_summaries)
    if delete_summaries:
        summary_lines.append(f"deletes ({len(valid_deletes)}):")
        summary_lines.extend(delete_summaries)
    summary = "\n".join(summary_lines) if summary_lines else "(no-op)"

    _t = time.perf_counter()
    diff_chunks: list[str] = []
    n_hunks = 0
    for path, new_content in staged_edits.items():
        d, h = _diff_html(edit_originals[path], new_content, path, kind="edit")
        if d:
            diff_chunks.append(d)
            n_hunks += h
    for path, content in staged_creates.items():
        d, h = _diff_html("", content, path, kind="create")
        if d:
            diff_chunks.append(d)
            n_hunks += h
    for path in valid_deletes:
        d, h = _diff_html(delete_originals.get(path, ""), "", path, kind="delete")
        if d:
            diff_chunks.append(d)
            n_hunks += h

    n_files = len(staged_edits) + len(staged_creates) + len(valid_deletes)
    perf["diff"] = time.perf_counter() - _t

    # ---- Open browser, block on user decision ----
    _t = time.perf_counter()
    approved, comment = _gate_with_browser("".join(diff_chunks), summary, n_files)
    perf["wait"] = time.perf_counter() - _t

    if not approved:
        perf["total"] = time.perf_counter() - t0
        _perf_log(
            f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] rejected "
            f"files={n_files} hunks={n_hunks} "
            f"stage_edits={perf['stage_edits']:.3f}s "
            f"diff={perf['diff']:.3f}s wait={perf['wait']:.3f}s "
            f"total={perf['total']:.3f}s"
        )
        msg = "REJECTED by user"
        if comment.strip():
            msg += f"\nuser comment: {comment.strip()}"
        msg += "\n(no files written)"
        return msg

    # ---- Approved — flush ----
    _t = time.perf_counter()
    written: list[str] = []
    try:
        for path, content in staged_edits.items():
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            written.append(path)
        for path, content in staged_creates.items():
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            written.append(path)
        for path in valid_deletes:
            os.remove(path)
    except OSError as e:
        return (
            f"PARTIAL FAILURE during flush: {e}\n"
            f"wrote {len(written)} file(s) before failure:\n"
            + "\n".join(f"  • {p}" for p in written)
            + "\nfilesystem is in an intermediate state — inspect manually."
        )

    perf["flush"] = time.perf_counter() - _t
    perf["total"] = time.perf_counter() - t0
    _perf_log(
        f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] applied "
        f"files={n_files} hunks={n_hunks} "
        f"stage_edits={perf['stage_edits']:.3f}s "
        f"diff={perf['diff']:.3f}s wait={perf['wait']:.3f}s "
        f"flush={perf['flush']:.3f}s total={perf['total']:.3f}s"
    )

    msg = f"applied:\n{summary}"
    if comment.strip():
        msg = f"applied (user comment: {comment.strip()!r}):\n{summary}"
    return msg


if __name__ == "__main__":
    mcp.run()
