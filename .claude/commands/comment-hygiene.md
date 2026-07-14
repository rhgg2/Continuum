---
description: Comment-hygiene pass on the working-tree diff by default, or on named files (cleanup mode). Spawns a sonnet subagent that fixes every flagged violation.
---

One pass. No iterative refinement.

**Scope.** No file args → diff mode: only violations the working-tree diff touches (what `/commit` uses). File args (`$ARGUMENTS`) → cleanup mode: the named files checked whole, regardless of git state. Cleanup mode surfaces pre-existing violations the current change never touched — that is the point; expect a longer list.

Hand the pass to a subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet`. It owns the pass end to end; do not pre-read or fix comments here. Pass it the file arguments `$ARGUMENTS` (none → diff mode), and prompt it with:

> Run `tools/comment_hygiene.py <paths>` from the repo root (omit `<paths>` for diff mode). It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, and contiguous WHY-comment runs >2 lines outside `tests/` (specs are exempt from the run cap; section dividers are not WHY lines). Fix every violation it names, then re-run until clean. Resolve each violation by trimming the comment to its load-bearing content, or by moving a longer WHY to `docs/<file>.md` with a one-line pointer at the site. NEVER resolve a violation by reverting the comment to a prior state or deleting the WHY wholesale — the content must survive in compliant form. Touch only comments the script flags. Report the files you changed and a one-line note per fix.

When it returns, eyeball its summary; don't re-audit.
