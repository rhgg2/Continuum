---
description: Adversarial review of the working-tree diff (tree vs HEAD). Spawns a fresh subagent on the current model that gets the change's intent, then tries to break it.
---

One pass. No iterative refinement.

1. `git status --porcelain`. Empty → clean tree; say so and stop. Don't spawn.
2. Write the **intent summary** yourself — you have the change's purpose from this conversation; a cold subagent wouldn't. A few sentences: what the change is meant to do, which layer it touches, what it must not break. Glance at `git diff --stat` to confirm scope; don't paste the full diff — the subagent reads that itself.
3. Spawn one subagent — Agent tool, `subagent_type: general-purpose`, **omit `model`** so it inherits the current session model. Hand it the intent summary in place of `<INTENT>`. It owns the review end to end and does **not** spawn further subagents. Prompt it with:

> You are an adversarial reviewer. Assume the change below is subtly wrong until you have genuinely tried and failed to break it. Your job is to surface the strongest objections, not to praise.
>
> **Intended change:** <INTENT>
>
> **See the whole diff first.** Run `git status --porcelain` to enumerate every path, then `git --no-pager diff HEAD` for tracked edits. Untracked files (status `??`) do **not** appear in that diff — Read each one in full. You are reviewing the entire working tree on top of HEAD, additions included.
>
> **Judge against intent and against the codebase.** This is a layered manager stack (see `CLAUDE.md`); use `mcp__readium_docs__map_query` and `map/<file>.map` / `docs/<file>.md` to check the change against the invariants and layering it touches — don't review it in a vacuum. Hunt specifically for: logic bugs and off-by-ones; unhandled cases (nil, empty, boundary); broken invariants or `--contract:`/`--invariant:` annotations; layering violations (a layer reaching through its neighbour); changes upward-propagation misses (a mutation not signalled to the layer above); dead orphans the change left behind; and — most important — ways the change fails to actually achieve its stated intent.
>
> **Do not edit any file.** Comment only.
>
> Report findings ranked most-severe first. For each: a one-line claim, the `file:line`, and a concrete failure scenario (inputs/state → wrong result). If after real effort you cannot break it, say so plainly and name what you checked. End with the single objection you are least sure about but think most worth a human's attention.

4. When it returns, relay its findings — ranked as given. Don't re-audit or fix here; that's a separate decision.
