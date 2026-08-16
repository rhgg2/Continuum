#!/usr/bin/env python3
"""PreToolUse(Bash) hook: auto-approve commands confined to the session scratchpad.

Spike work lives under /tmp/claude-<uid>/ — throwaway by contract, so a prompt there
protects nothing. But the shapes spike runs take (heredocs, loops, substitutions,
redirections) are exactly the shapes no Bash() prefix rule can match, so every variant
prompts afresh. commit-agent-allow.py asks "do I recognise this command?"; that
question has no good answer here. This asks the one that does: "can this command reach
anything outside the scratchpad?"

Confinement is textual, over the command with quoted-heredoc bodies lifted out. The
split matters because the typical spike command is `cd <spike> && cat > probe.lua
<<'LUA'` around a body of Lua, and Lua is made of the very strings a shell scan reads
as reaching: `..` is concat, `~=` is not-equals, `root..'/take.lua'` looks like an
absolute path. A quoted-heredoc body cannot execute during the call and the file it
lands in is named in the command proper, so the body is data and gets the data test:
any absolute path in it whose first component is a real filesystem root (/Users, /etc,
…) must sit under the scratchpad; fragments like '/take.lua' pass. A `..` in a body is
no less reaching than one in the command proper, so it resolves the same way. Only
*quoted* delimiters are lifted — an unquoted one expands inside the body, so those
commands are scanned whole (and a Lua body then refuses, nudging toward the quoted form
house style prefers).

The command proper carries the strict contract:

- It opens with `cd` into the scratchpad, so relative paths and redirections resolve
  inside the throwaway tree. Later `cd`s may be relative and may not climb, which keeps
  that opening directory the shallowest the cwd can be; a bare, `..`, `~` or `$`-shaped
  target refuses.
- Every absolute path sits under the scratchpad, /dev/* excepted.
- Every `..` resolves against that opening directory and must land under it. The scan
  cannot tell a traversal from Lua's concat operator, so it judges both the same way,
  by where they land: `'../../../?.lua'` climbs to a directory still inside the tree,
  and `root..'/take.lua'` normalises to a harmless name below it.
- No route around the scan: `~`, sudo, pushd/popd, and the variables that name outside
  places ($HOME and friends) each refuse the whole command.

Silence is the safe answer and costs one prompt. What stays promptable: commands with
no cd anchor, anything referencing the main tree, unquoted heredocs.
"""

import json
import os
import re
import sys

ROOTS = (
    f"/private/tmp/claude-{os.getuid()}/",
    f"/tmp/claude-{os.getuid()}/",
)

# Each of these can reach outside the scratchpad without writing an absolute path the
# scan below would see. Substring match, so an innocent filename can trip one — that
# refuses, which is the harmless direction.
FORBIDDEN = (
    "~", "sudo", "pushd", "popd",
    "$HOME", "${HOME", "$TMPDIR", "${TMPDIR", "$PWD", "${PWD",
    "$OLDPWD", "${OLDPWD", "$CLAUDE_PROJECT_DIR", "${CLAUDE_PROJECT_DIR",
)

# First components that mark an absolute path as naming the real filesystem rather
# than being a Lua/sed fragment like '/take.lua'. Used for heredoc bodies only.
REAL_ROOTS = frozenset((
    "Applications", "Library", "System", "Users", "Volumes",
    "bin", "cores", "etc", "home", "opt", "private", "sbin", "tmp", "usr", "var",
))

# An absolute path: a `/` not glued to a preceding word (which would make it
# relative, confined by the cd anchor) nor to `)`/`]` (which would make it Lua
# division), then its run of path characters.
ABS_PATH = re.compile(r"(?<![\w.+%@)\]-])/[\w.+%@/-]+")

# Every `cd` token and its first argument. Bare `cd` (empty capture) goes to $HOME,
# so an empty argument refuses.
CD = re.compile(r"(?<![\w./-])cd(?![\w./-])[ \t]*([^\s;&|)]*)")

# Anything holding `..`, taken with the run of path characters around it so the whole
# thing can be resolved as a path.
DOTDOT = re.compile(r"[\w.+%@/-]*\.\.[\w.+%@/-]*")

HEREDOC = re.compile(r"<<-?[ \t]*(?:'(\w+)'|\"(\w+)\")")


def split_heredocs(command):
    """Split into (command proper, quoted-heredoc bodies); (None, None) if unterminated.

    Line-by-line, matching bash: a body starts on the line after its `<<'TAG'` and
    runs to the line holding TAG alone; markers inside a body are body text. Ending a
    body early on a lookalike line only moves text into the stricter scan.
    """
    proper, bodies, pending = [], [], []
    for line in command.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            else:
                bodies.append(line)
            continue
        proper.append(line)
        for m in HEREDOC.finditer(line):
            pending.append(m.group(1) or m.group(2))
    if pending:
        return None, None
    return "\n".join(proper), "\n".join(bodies)


def proper_paths_confined(proper):
    return all(
        path.startswith("/dev/") or path.startswith(ROOTS)
        for path in ABS_PATH.findall(proper)
    )


def body_paths_confined(bodies):
    for path in ABS_PATH.findall(bodies):
        if path.startswith(ROOTS):
            if not os.path.normpath(path).startswith(ROOTS):
                return False
        elif path.lstrip("/").split("/")[0] in REAL_ROOTS:
            return False
    return True


def dotdots_confined(text, anchor):
    return all(
        os.path.normpath(os.path.join(anchor, token)).startswith(ROOTS)
        for token in DOTDOT.findall(text)
    )


def cd_anchor(proper):
    """The directory relative paths resolve against, or None if the `cd`s aren't confined.

    The first `cd` names it and must be absolute and inside the scratchpad. Later ones
    may be relative but may not climb, so the cwd only ever goes deeper and the anchor
    stays the shallowest it can be — which is what makes it the worst case to resolve a
    `..` against.
    """
    targets = [t.strip("'\"") for t in CD.findall(proper)]
    if not targets or not targets[0].startswith(ROOTS):
        return None
    for target in targets:
        relative = target and not target.startswith(("/", "-", "$", "~"))
        if not target.startswith(ROOTS) and not (relative and ".." not in target):
            return None
    return targets[0]


def command_allowed(command):
    proper, bodies = split_heredocs(command)
    if proper is None:
        return False
    tokens = proper.split(None, 1)
    if not tokens or tokens[0] != "cd":
        return False
    if any(marker in proper for marker in FORBIDDEN):
        return False
    anchor = cd_anchor(proper)
    return (
        anchor is not None
        and proper_paths_confined(proper)
        and body_paths_confined(bodies)
        and dotdots_confined(proper, anchor)
        and dotdots_confined(bodies, anchor)
    )


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command_allowed(command):
        return

    json.dump(
        {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "scratchpad: command confined to the session scratchpad",
        }},
        sys.stdout,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
