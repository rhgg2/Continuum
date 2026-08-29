#!/usr/bin/env python3
"""PreToolUse(Bash) hook: auto-approve the commit-finisher agent's own commands.

/commit hands its mechanical half to a subagent whose every command is predictable —
status, diff, the hygiene script, add, commit. Prompting for those is pure
interruption: running /commit *was* the approval. So this grants a named set, and only
within that agent — `agent_id` is present only inside a subagent and `agent_type` names
it, so the main session's permissions are untouched.

A prefix allow-list in settings.json cannot do this job, because the agent varies the
shape it sends: `python3 tools/comment_hygiene.py || echo done` matches no
`Bash(python3 *)` rule. So this parses the command instead, and every segment of a
compound has to be recognised for the whole to be allowed.

Silence is the safe answer and costs one prompt. Anything unparsed, unrecognised, or
able to smuggle a second command past the segment split — substitution, redirection, an
unbalanced quote — falls through to the normal permission flow. Allowing a command this hook did
not fully understand would cost the boundary itself, and the boundary is the whole
point: what stays promptable is what nobody anticipated, `git reset --hard` on a tree
holding someone else's work being the case that motivated keeping it.
"""

import json
import shlex
import sys

AGENT = "commit-finisher"
HYGIENE = "tools/comment_hygiene.py"

# Leaders a commit run may use. Two tokens where the bare verb is too broad to grant:
# `git` alone would carry checkout and reset in with it.
ALLOWED_PREFIXES = (
    ("git", "status"), ("git", "diff"), ("git", "log"), ("git", "show"),
    ("git", "rev-parse"), ("git", "add"), ("git", "commit"),
    ("cd",), ("pwd",), ("ls",), ("echo",), ("true",),
)

# Only these join segments. Any other operator token (`>`, `<`, `>&`, `(`) means a shape
# the segment walk below does not model, so the command is left to the normal flow.
SEPARATORS = frozenset({"&&", "||", ";", "|"})
PUNCTUATION = frozenset("();<>|&")

# Expansions that run a command of their own, invisible to a token walk. Bare `$VAR` is
# fine — it cannot execute — so `cd "$CLAUDE_PROJECT_DIR"` still passes.
SMUGGLERS = ("$(", "`")


def segment_allowed(tokens):
    if not tokens:
        return False
    if tokens[0].endswith(HYGIENE):
        return True
    if tokens[0] == "python3":
        return len(tokens) > 1 and tokens[1].endswith(HYGIENE)
    return any(tuple(tokens[:len(prefix)]) == prefix for prefix in ALLOWED_PREFIXES)


def command_allowed(command):
    if any(smuggler in command for smuggler in SMUGGLERS):
        return False
    # Per line, because shlex reads a newline as plain whitespace: one walk over the
    # whole thing would see `git add -A` + newline + `rm -rf /` as a single segment led
    # by `git add`, and allow it. Splitting first also disposes of a newline *inside* a
    # quoted argument, since neither fragment then parses.
    lines = [line for line in command.split("\n") if line.strip()]
    return bool(lines) and all(line_allowed(line) for line in lines)


def line_allowed(line):
    try:
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return False

    segment = []
    for token in tokens:
        # A quoted argument that is *only* punctuation reads as an operator here. That
        # misreads `-m ";"` as a split and refuses it, which is the harmless direction.
        if token and PUNCTUATION.issuperset(token):
            if token not in SEPARATORS or not segment_allowed(segment):
                return False
            segment = []
        else:
            segment.append(token)
    return segment_allowed(segment)


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return
    if not payload.get("agent_id") or payload.get("agent_type") != AGENT:
        return
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command_allowed(command):
        return

    json.dump(
        {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "commit-finisher: recognised commit-run command",
        }},
        sys.stdout,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
