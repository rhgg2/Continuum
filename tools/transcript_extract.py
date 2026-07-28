#!/usr/bin/env python3
"""Extract the human-readable conversation from Claude Code transcripts.

A .jsonl transcript is mostly machinery: tool calls and their results,
injected context, file-history snapshots, mode changes. This pulls out what
was actually said, and drops the rest.

    transcript_extract.py --index DIR              list sessions, newest last
    transcript_extract.py FILE                     one session to stdout
    transcript_extract.py DIR --out OUTDIR         one .md per session

Assistant thinking is excluded by default; --thinking puts it back. Subagent
runs are separate transcripts rather than nested turns, so they are included
by naming their files.
"""

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

# Injected context and local-command output arrive inside the user turn but
# were never typed by anyone; a command invocation was, so it survives as a
# one-line marker rather than being stripped with them.
SYSTEM_REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
LOCAL_STDOUT = re.compile(r"<local-command-stdout>.*?</local-command-stdout>", re.S)
COMMAND_CALL = re.compile(
    r"<command-name>(?P<name>[^<]*)</command-name>\s*"
    r"(?:<command-message>[^<]*</command-message>\s*)?"
    r"(?:<command-args>(?P<args>[^<]*)</command-args>)?",
    re.S,
)
BLANK_RUN = re.compile(r"\n{3,}")


def as_command_marker(match):
    args = (match.group("args") or "").strip()
    name = match.group("name").strip()
    return f"[{name} {args}]" if args else f"[{name}]"


def clean(text):
    text = SYSTEM_REMINDER.sub("", text)
    text = LOCAL_STDOUT.sub("", text)
    text = COMMAND_CALL.sub(as_command_marker, text)
    return BLANK_RUN.sub("\n\n", text).strip()


def records(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def local_time(stamp):
    if not stamp:
        return None
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def read_session(path, include_thinking=False):
    """Return (meta, turns) from one transcript, in a single pass."""
    meta = {"session": path.stem, "title": None, "branch": None,
            "first": None, "last": None, "agent": False}
    turns = []

    for record in records(path):
        kind = record.get("type")

        # A subagent's transcript carries agent-name where a session carries
        # ai-title, so either one names the file.
        if kind == "ai-title" and record.get("aiTitle"):
            meta["title"] = record["aiTitle"]
        if kind == "agent-name" and record.get("agentName"):
            meta["title"] = meta["title"] or record["agentName"]
            meta["agent"] = True
        if record.get("gitBranch"):
            meta["branch"] = record["gitBranch"]
        stamp = record.get("timestamp")
        if stamp:
            if meta["first"] is None or stamp < meta["first"]:
                meta["first"] = stamp
            if meta["last"] is None or stamp > meta["last"]:
                meta["last"] = stamp

        if kind not in ("user", "assistant"):
            continue
        if record.get("isMeta"):
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue

        content = message.get("content")
        spoken = []
        if isinstance(content, str):
            spoken.append((kind, content))
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    spoken.append((kind, block.get("text", "")))
                elif block.get("type") == "thinking" and include_thinking:
                    spoken.append(("thinking", block.get("thinking", "")))

        for role, raw in spoken:
            text = clean(raw)
            if not text:
                continue
            label = role
            if record.get("isCompactSummary"):
                label = f"{role} (compact summary)"
            if turns and turns[-1]["label"] == label:
                turns[-1]["text"] += "\n\n" + text
            else:
                turns.append({"label": label, "stamp": stamp, "text": text})

    return meta, turns


def render(meta, turns):
    started, ended = local_time(meta["first"]), local_time(meta["last"])
    lines = [f"# {meta['title'] or meta['session'][:8]}", ""]
    lines.append(f"- session: `{meta['session']}`")
    if started:
        span = started.strftime("%Y-%m-%d %H:%M")
        if ended:
            span += " → " + ended.strftime("%H:%M")
        lines.append(f"- when: {span}")
    if meta["branch"]:
        lines.append(f"- branch: {meta['branch']}")
    if meta["agent"]:
        lines.append("- subagent run")
    lines.append(f"- turns: {len(turns)}")
    lines.append("")

    for turn in turns:
        at = local_time(turn["stamp"])
        heading = f"### {turn['label']}"
        if at:
            heading += f" · {at.strftime('%H:%M')}"
        lines += ["---", "", heading, "", turn["text"], ""]

    return "\n".join(lines) + "\n"


def slug(text, limit=48):
    cleaned = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return cleaned[:limit].rstrip("-")


def transcripts(paths):
    for raw in paths:
        path = Path(raw).expanduser()
        if path.is_dir():
            yield from sorted(path.glob("*.jsonl"))
        elif path.exists():
            yield path
        else:
            print(f"skipping missing path: {path}", file=sys.stderr)


def within(meta, since, until):
    day = (meta["first"] or "")[:10]
    if since and day < since:
        return False
    if until and day > until:
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", help="transcript .jsonl files or directories")
    parser.add_argument("--out", metavar="DIR", help="write one .md per session")
    parser.add_argument("--index", action="store_true", help="list sessions instead of extracting")
    parser.add_argument("--since", metavar="YYYY-MM-DD", help="sessions starting on or after")
    parser.add_argument("--until", metavar="YYYY-MM-DD", help="sessions starting on or before")
    parser.add_argument("--min-turns", type=int, default=0, metavar="N",
                        help="skip sessions with fewer than N spoken turns")
    parser.add_argument("--thinking", action="store_true", help="include assistant thinking")
    args = parser.parse_args()

    outdir = Path(args.out).expanduser() if args.out else None
    if outdir:
        outdir.mkdir(parents=True, exist_ok=True)

    sessions = []
    for path in transcripts(args.paths):
        meta, turns = read_session(path, args.thinking)
        if len(turns) < args.min_turns or not within(meta, args.since, args.until):
            continue
        sessions.append((meta, turns))
    sessions.sort(key=lambda pair: pair[0]["first"] or "")

    if args.index:
        for meta, turns in sessions:
            started = local_time(meta["first"])
            when = started.strftime("%Y-%m-%d %H:%M") if started else "?" * 16
            print(f"{when}  {len(turns):>4} turns  {meta['session'][:8]}  "
                  f"{meta['title'] or ''}")
        print(f"\n{len(sessions)} sessions", file=sys.stderr)
        return

    for meta, turns in sessions:
        body = render(meta, turns)
        if not outdir:
            sys.stdout.write(body)
            continue
        started = local_time(meta["first"])
        stamp = started.strftime("%Y-%m-%d-%H%M") if started else "undated"
        # A resumed session shares its parent's title and opening timestamp, so
        # the session id is what keeps two of them from landing on one file.
        name = slug(meta["title"])
        stem = f"{stamp}-{name}-{meta['session'][:8]}" if name else f"{stamp}-{meta['session'][:8]}"
        (outdir / f"{stem}.md").write_text(body, encoding="utf-8")
    if outdir:
        print(f"wrote {len(sessions)} sessions to {outdir}", file=sys.stderr)


if __name__ == "__main__":
    main()
