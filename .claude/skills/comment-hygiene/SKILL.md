---
name: comment-hygiene
description: Comment-hygiene pass
disable-model-invocation: true
---

One pass. No iterative refinement.

**Scope.** Diff mode is the default: only violations the working-tree
diff touches (what `/commit` uses), narrowed to the named files when
`$ARGUMENTS` names any. `--all` switches to cleanup mode — the named
files checked whole, regardless of git state. Cleanup mode surfaces
pre-existing violations the current change never touched; that is the
point, so expect a longer list. Pass `--all` only when the user asks
for a whole-file pass.

Hand the pass to a subagent — Agent tool, `subagent_type:
general-purpose`, `model: sonnet`. It owns the pass end to end; do not
pre-read or fix comments here. Pass it the file arguments `$ARGUMENTS`
(none → diff mode), and prompt it with:

> Run `tools/comment_hygiene.py <paths>` from the repo root (omit
> `<paths>` for the whole diff; add `--all` to check the named files
> whole rather than just their diff). It flags
> `--pre:`/`--post:`/`--invariant:`/`--contract:`/`--emits:`/`--reaper:`
> lines >100 chars, `--shape:` lines >400 chars, comments citing a `design/` doc
> other than the live plan's, and
> contiguous WHY-comment runs >2 lines outside `tests/` (specs are
> exempt from the run cap; section dividers are not WHY lines). Fix
> every violation it names,
> then re-run until clean. Resolve each violation by trimming the
> comment to its load-bearing content, by splitting a multi-clause
> annotation into one per line, or by moving a longer WHY to
> `docs/<file>.md` with a one-line pointer at the site. A pointer
> names `docs/`, never `design/`. NEVER resolve
> a violation by reverting the comment to a prior state or deleting
> the WHY wholesale — the content must survive in compliant form.
> Touch only comments the script flags.
>
> You cannot count characters by eye, so don't draft a trim and hope.
> Draft two or three candidates per over-length line and measure the
> batch in one call, feeding `--measure` the candidate lines on stdin
> (indentation included); it prints each against its cap, and you take
> the longest that reads `ok`. Where the report names a clause count a
> split is worth considering, but check each resulting line still
> names its own subject — a clause like "onClose sweeps it" loses its
> antecedent the moment it leaves the parent line.
>
> Report the files you changed and a one-line note per fix.

When it returns, eyeball its summary; don't re-audit.
