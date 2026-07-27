# memory-as-claims — the auto-memory store as revisable claims, not a fact list

> opened: 2026-07-27 · status: in flight — `plan/memory-as-claims.md`
>
> Designed in conversation rather than in a design round; this doc is the
> record. The decisions below are settled — if one needs reopening, it
> reopens here.

## The problem

The auto-memory store at `~/.claude/projects/-Users-rgarner-Documents-Code-Continuum/memory/`
is 24 files, each holding one decontextualised fact, indexed by a one-line
abstract in `MEMORY.md`. Only `MEMORY.md` is loaded at session start (capped
at 200 lines / 25KB, whichever comes first); topic files load only when Claude
chooses to read one. There is no semantic recall and no memory tool — the
system prompt's claim that "recalled memories arrive in `<system-reminder>`
blocks" describes something that does not happen. **The index line is
therefore the entire recall mechanism.**

Three things follow. The store answers only questions that are already
classifiable — a trigger fires on recognition, so it is weakest exactly where
a session is most lost. It holds conclusions and discards the generator, so it
helps with gotcha #4 only if #4 is already filed, and never with #5. And it is
inert: it accretes, nothing in it can be wrong, so nothing is ever learned —
only added.

A rising-sea pass over all 24 files plus the `~/.claude/wonder/` ledger found
that the store is **filed by where the bug happened** (`jsfx_`, `reaimgui_`,
`bash_`) while its real structure is **how the bug worked** — and those cut
across the platform boundaries the filenames organise by.

## Decisions

**D1 — One unit: a claim, with a subject and a standing.** Subject is world /
our construction / us. Standing runs `open` → `observed` → `load-bearing`,
with `refuted` as a fall. The generative mechanism is that a claim *travels*:
noticed, then confirmed by an incident, then promoted when three observations
rhyme. Instantiated at zero — every claim `observed`, no laws — it reproduces
today's flat list exactly, so it is adoptable without a flag-day.

**D2 — The four-type taxonomy prunes to subject.** `feedback` vs `project` was
provenance, not kind: both are claims about our construction, differing only
in whether Richard said it out loud, which `originSessionId` already records.
`reference` was mostly misfiled documentation — `reference_commandmanager_limits`
describes cmgr's current shape and ends by pointing at `docs/commandManager.md`,
which CLAUDE.md already rules is what is true now. Memory keeps what docs
structurally cannot: incidents, laws, and open questions.

**D3 — A claim states what is true, not what to do.** This is the load-bearing
decision. Working under a weight of instructions is stifling; instructions
compete with one another for attention and dilute, whereas a model that changes
what you *see* compounds. Each `us` finding converts: "check whether you know
the dirty window" becomes "Continuum is built to know what changed", and the
recompute simply stops being attractive. The converted form is shorter and does
more work — that is the tell that it is the real one.

**D4 — Conventions go to CLAUDE.md; insights go to the store.** Some things are
arbitrary and can only be told (`config:` as a commit scope); manufacturing an
insight for them would be the same dishonesty as manufacturing a crystal. The
line is principled rather than convenient: a convention has no standing — it is
in force or it isn't — while only a claim about how something works can be held
provisionally, strengthened, or refuted.

**D5 — Promotion bar: mechanism, not symptom.** Three instances across
*different sessions*, rhyming on a mechanism. "Does it yield a check you could
run before the mistake?" is kept as a **falsifier**, because it separates
mechanism from symptom — but explicitly not as the output format, since that
test selects for instructions and is why the first pass came back shaped like
rules. The bar's first use was on itself: "JSFX has no error surface" failed
(two of its four instances are not error-reporting failures at all) and was
replaced by "JSFX doesn't have the boundaries you assume it has", which stands.

**D6 — The always-loaded budget buys claims, not abstracts, and there is no
evidence tier.** Around nine load-bearing claims replace the 24 index lines in
`MEMORY.md`. D1 already settles what becomes of the instances: an instance is
not a different kind of thing, it is a claim at `observed` standing. So each
existing file goes to exactly one of four destinations — **folded** into the law
it evidences, carrying its specifics inline (the JSFX four collapse to one,
~59 lines to ~25); **kept** as an unpromoted claim where it is a genuine
singleton (`no_legacy_data`, `early_file_dates`); **retired to `docs/`** where
it was project documentation misfiled into a private store (`config_schema` and
`commandManager_limits` both already end by pointing at their doc); or **to
CLAUDE.md** where it is a convention (D4). A few files evidence two laws —
`harness_take_roundtrip` grounds both vantage and duplicate-state — and are
cited by both rather than absorbed by either. The store lands at roughly ten
files.

*2026-07-27, on carrying out the retirements.* "Misfiled documentation" was the
right reading, and cheaper than expected: `project_config_schema` retired to
`docs/configManager.md` with **no doc edit at all** — unknown-keys-raise,
tolerant pruning, deep-clone-at-boundary and the dataStore split were all
already there — and `reference_commandmanager_limits` needed only its
prefix-capture limits carried across, the one sentence in either file that lived
nowhere else. Almost nothing was being *stored*; it was being duplicated.
`feedback_command_table_tidy` went to CLAUDE.md alongside `commit_scope_config`
rather than staying a singleton, on D4's test — nothing about it could be
refuted, only followed or not.

*2026-07-27, on the fold itself.* The store lands at ten files, as predicted,
but not the ten predicted. `gotchas_reaimgui_api` was slated for absorption
into duplicate-state and could not be: that law takes two of its seven
sections, and the other five — `EnterReturnsTrue` not committing `buf`,
`BeginPopup` not inheriting `NoNav`, `OpenPopup` anchoring to the mouse, `Esc`
not bubbling, the `SameLine`/`Selectable` overlap pair — share no mechanism
with each other beyond *the signature is right and the runtime isn't*. That is
itself a claim, so the file stays as `world_reaimgui_behaviour` at `observed`,
and D6's "folded / kept / to docs / to CLAUDE.md" gains no fifth destination.
Four other files carried a **remedy** the law had abstracted away — the law
says what is true, and D3 is right that this is the more useful form, but the
fix is not recoverable from it. Three went to the claim that generalises them
(`bash -n`, `python3` for hook date maths) and two to docs (`git diff --text`
and regen-all-maps to CONVENTIONS, the warm/collect/report-every-pass recipe to
the bridge cookbook). The lesson for a future fold is that the delta check has
two halves, not one: does the mechanism survive, *and* does the fix.

One consequence not anticipated: every keeper's git creation date reads
2026-07-27, because that is when the store was committed into the repo. The
bulk-import claim, folded into vantage an hour earlier, describes exactly this
artefact — so the keepers carry `originSessionId` and no `opened:` rather than
a date that isn't theirs.

One find sharpens the problem statement above. Its index line asserted that cmgr
scopes "don't stack (one active at a time)", which contradicts both cmgr and the
file it indexed. So the store is worse than inert: an always-loaded line had been
quietly wrong for some time, and being unfalsifiable in practice is not the same
as being right. That is an argument for standing — a claim that can be refuted is
a claim someone eventually checks.

**D7 — `wonder` folds in as the `open` end.** Curiosities are the raw material
of insight, and isolation is what killed the ledger — seven entries, one
resolved in eight days, and that one a test entry. But an `open` claim carries
**no obligation to be promoted**: "why do trackers number rows in hex?" feeds
no theory and needn't. If every entry is judged on whether it is raw material,
the noticing stops being genuine.

**D8 — No new machinery in the first pass.** Promotion detection, surfacing
hooks, and `anchors:`/staleness checking are all deferred until we have lived
with the shape. Abstracting on anticipation is the failure this design exists
to avoid.

**D9 — The store lives in the repo, under version control.** Files move to
`.claude/agent-memory/`, tracked; the documented `autoMemoryDirectory` setting
(absolute path) goes in `.claude/settings.local.json`, which a global gitignore
rule keeps out of the repo, so the machine-specific path never lands in a
commit while the content does. No symlink is needed. Git also replaces the
archive step outright — the 24 files are committed unchanged *before* any fold,
so the compression lands as a diff against its own originals. Because a
misresolved path fails silently, the SessionStart hook asserts `MEMORY.md`
resolves and says so loudly if not. The consequence accepted knowingly: the
`modified:` frontmatter timestamp updates on every write, so committed memory
will show timestamp churn. Take the churn; a strip-on-commit hook would be D8's
mistake.

**D10 — Claims carry no verbatim quotation.** The `us` claims were derived from
Richard's own words, and those words are not going into the repo: provenance is
a session id and a date, and nothing else. This costs the design nothing, and
D3 explains why — a claim states what is true, so if it needs a quotation to be
persuasive it is a rule leaning on authority rather than an insight that changes
what you see. The quotes were scaffolding for the derivation, not content of the
result. The corollary matters more: a `us` claim has a subject that **changes**,
while EEL2 does not. So standing on the `us` axis decays where standing on the
`world` axis persists, and a `us` claim that has stopped firing should fall back
toward `open` rather than sit at `load-bearing` forever. The corpus was mined
once and deleted, miners included.

## What the analysis found

The claims live in the store; these one-liners are here so the derivation is
not lost.

**World** — *duplicate state, and you updated one copy* (SetAllEvts' stale
playback cursor, ImGui's internal buffer and derived ID, `@init` vs `heap_top`,
harness tags vs the wire). *The vantage point is not neutral* (the Bash tool's
`find` vs a hook's BSD `find`, harness vs REAPER, GC-inflated first timings,
git-blind `.map` files). *JSFX doesn't have the boundaries you assume* — scoped
to EEL2, with `function ... local()` as the one real boundary it does have.

**Our construction** — *state has exactly one owner*, the deliberate inverse of
the duplicate-state law: page/view, the page as coordinator, cm as sole truth,
`chrome.row`. Neither side's files knew about the other; the remedy had been
arrived at independently of the disease.

**Us** — one parent, *reconstruction feels cheaper than retrieval because it
doesn't interrupt the flow of composing an answer, and the feeling of
already-knowing is identical whether or not you know* — with five shapes: forks
whose branches share an unread premise; recompute where the delta is already
held; special-casing at the noticing site rather than the owning one; settling
REAPER questions in the harness; and shipping a plausible causal story as a fix.

## What the evidence cost, and what it corrected

The `us` claims came from mining 929 session transcripts. Two findings worth
keeping.

The patches review channel is **empty**: 1,142 review rounds, 5,814 hunks
accepted, 6 rejected, 9 edited, 7 feedback blocks, and one inflight-guidance
message ever — 99.74% acceptance. That is not a broken review loop, it is
CLAUDE.md's "have the design settled beforehand" working as designed.
Correction in this collaboration does not look like rejection; it looks like
conversation, upstream of any staged edit.

An earlier count of "607 feedback blocks" was an artefact: a `grep` for the
string matched skill documentation describing the mechanism, MCP source
containing the word, and the grep commands from the same session. A plan was
built on it before it was checked — a live instance of the parent `us` claim,
an hour after the vantage law was written down.

The real corpus is prose: 3,858 genuine user messages, 211 carrying redirect
markers, ~120 effective after near-duplicates and ~20 false positives. The
extraction is worth preserving so that a claim's standing can be re-tested
against fresh sessions rather than assumed.
