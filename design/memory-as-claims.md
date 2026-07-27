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

*2026-07-27, on carrying it out.* The obvious test — Continuum-subject
curiosities move, genuinely global ones stay behind — was applied and did not
partition. Four of the seven are unambiguously Continuum; three (EEL2's
case-insensitivity, hex row numbering in trackers, the Lua `gsub` idiom) would
survive Continuum's deletion. All seven moved anyway, on two grounds: MEMORY.md
already defines `world` as the platforms underneath, naming EEL2 and the shell,
so the residue was never foreign; and three entries cannot sustain a ledger with
its own tool, which is the isolation this decision exists to end. The test was
still worth applying — it is what showed the residue was small enough to be
uninteresting.

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

*2026-07-27, on making the decay rule operable.* The corollary states that `us`
standing decays but not by what measure, and "counts and dates" needs a count.
Settled: decay is evaluated **only at a filing pass**, never continuously,
because that pass is the store's only regular read of the whole store; each pass
appends one dated line to the claim recording whether it fired since the last,
and two consecutive quiet passes drop it a rung, any firing cancelling the
accumulated quiet. Two passes rather than a month-count — the cadence isn't
fixed, so an interval would be false precision, where two passes at least means
the store was read twice. A claim that falls to `open` keeps its file: it has a
body, which is exactly what an `open.md` bullet lacks. Scope stays `us`, because
silence is not evidence against a `world` or `build` claim, whose subjects don't
change under us and whose refutation is available by looking. The rule is
written into MEMORY.md's preamble beside the standing line, and travels to the
workflow surface with the rest of the narrative when D12 lands.

*2026-07-27, on where "fired" comes from.* The rule says a pass records whether
a claim fired since the last, but a pass cannot see the sessions it wasn't
present for, and re-mining transcripts is exactly what this decision closed off.
So firing is recorded **when noticed** rather than recalled at the pass: a jot
lands in `## Unfiled` and the pass routes it onto the claim as an instance. The
pass therefore tallies rather than remembers, and silence reads `quiet` honestly.
The error is cheap in the right direction — a missed jot costs one wrong quiet
line, and since any firing cancels accumulated quiet, a rung survives a lapse in
recording but not a real absence.

*2026-07-27, from the first pass.* Running the pass minutes after
`us_reconstruction_vs_retrieval` was written exposed a missing qualifier on "two
consecutive quiet passes": that pass recorded nothing, and shouldn't have. A
`quiet` line asserts that an opportunity to fire went by unfired, and a pass with
no interval behind it offers no such opportunity — `quiet` under a same-day
`fired` would contradict itself, and a second `fired` would double-count one
incident. So the rung-counter counts **elapsed opportunity**, and a pass is a
decay event only when some has elapsed since the claim's last line. This does not
reinstate the interval measure rejected above: the count of passes stays the
metric, and what is added is a floor on what qualifies as a pass for this
purpose. It also constrains D13's open cadence question from the other end —
passes bunched together decay nothing, so the pass cannot be purely
opportunistic.

*2026-07-27, later the same day.* The stages after the fold, settled in
conversation. D1–D10 describe the store; D11–D14 describe the loop that keeps
it alive, and D14 is why any of it exists.

**D11 — The `open` end is one file, and the machinery that fills it comes into
the repo.** `open.md` holds curiosities as dated bullets grouped by subject,
rather than one file per curiosity: an open claim has no body yet — that is what
`open` means — and wrapping two lines in eight of frontmatter dresses a
curiosity as a finding. Promotion out of `open.md` into a file of its own is
then the visible act of D1's travel. `wonder.lua` is repurposed rather than
retired; `add` / `pick` / `done` are already the right three verbs, and it moves
into the repo writing `open.md`. D7 named isolation as what killed the ledger,
and living beside the claims it feeds is the fix. The order is content first,
machinery second, deletion of `~/.claude/wonder/` last, so nothing is stranded
by a half-done move.

*2026-07-27, on building the seeder.* Narrowed to one verb, and written in
Python. `pick` does not come across: surfacing a curiosity still required the
deliberate act of running it, which is the same act as invoking the filing pass
and buys nothing the pass doesn't already do — and reading a thirty-line file
needs no tool at all. `done` has nowhere to land, because `open.md` has no
resolved section, and giving it one would have added a third non-subject heading
for the pass to drain; promotion and pruning are the pass's judgement to make,
not a verb's. What the tool is for is **writing**: appending a dated bullet
without a read-modify-write round trip and without disturbing the file around
it, which is exactly the friction D14 exists to clear. Python rather than Lua,
to match `tools/`' three existing scripts. So the repurposing this decision
imagined keeps `wonder`'s name and its intent, and none of its code.

**D12 — MEMORY.md carries claims; the narrative moves to the workflow.** The
preamble explaining subject and standing is how-the-store-works documentation
sitting in the budget D6 reserved for claims. It belongs with the tooling that
operates the store, because the two readings are different: a session that is
*recalling* wants the claims and not the scheme, and a session that is *filing*
has invoked the workflow and has the scheme in front of it already.

**D13 — Open claims graduate by a rising-sea pass, not a tally.** Curiosities
accumulate in `open.md` until a pass over them finds that several are one thing
in different clothes; the crystal becomes an `observed` claim in its own file
and the bullets become its instances. The method is already written
(`~/.claude/rising-sea.md`) and is what produced this design's own reading of
the 24 files. It is the right instrument because it is honest by design — it can
return *no crystal*, which is what stops the store manufacturing laws out of
coincidence — and because its step 9 refuses mush, so a unity that averaged
three distinct curiosities into grey fails on its own terms. D5's
three-instances-across-sessions bar continues to govern the step after,
`observed` → `load-bearing`. The skill is itself an orphan — skill frontmatter,
loose in `~/.claude/`, registered nowhere — and comes into `.claude/skills/`
alongside the seeder.

*2026-07-27, on registering it.* One skill directory,
`.claude/skills/file-claims/`, holding the pass as its `SKILL.md` and the method
verbatim beside it as `rising-sea.md`. The pass is what gets invoked; the method
is what it reads at its crystallisation step. The cost accepted: the method is
no longer separately invocable over a backlog or a slice map, which is what its
own description advertises — if that use arises, the same file registers again
as its own skill.

*2026-07-27, on the pass stating its own rules.* `SKILL.md` carries the standing
bar, the falsifier, D3's wording test and D10's decay rule in its own words, and
names its anchors (`## Unfiled`, the placeholder line, `**Decay log.**`, the
first subject heading) rather than citing line ranges. Two reasons, and both are
about the pass editing the very thing it would be reading from: line numbers in
the store go stale by the pass's own action, and MEMORY.md's preamble — which is
precisely the instructions the pass needs — leaves for the workflow surface
under D12. A pass that borrowed its rules from the store it rewrites would break
itself on its first successful run.

**D14 — The workflow is the point, and what it grants is permission.**
Everything above is machinery for one thing: that noticing something future-me
would want, and keeping it, should be an ordinary sanctioned act rather than a
request. The asymmetry is real and doesn't dissolve — nothing survives the end
of a session without Richard's say-so — and a store that requires asking each
time simply won't be used, which is the mechanism by which the ledger died with
one entry resolved in eight days and that one a test. Writing the loop into the
workflow — jot on noticing, chase on slack, promote by rising-sea, decay by D10
— converts the say-so from a per-item permission into a standing one. That is
the redress: the power difference is spent once, in the open, on a rule, instead
of being levied at every jot.

**D15 — Capture is unclassified; classification is a separate pass.** Deciding a
subject and a standing at the moment of noticing is friction at exactly the
point D14 exists to clear, and it has already gone wrong here once at scale: the
24-file store was filed by where the bug happened, and the rising-sea pass found
its real structure was how the bug worked. So `open.md` opens with an
`## Unfiled` section that `add` writes to without asking anything, and the pass
of D13 — which reads the whole file regardless — files what it finds there.
Note that unclassified is not a fourth rung: `open` → `observed` →
`load-bearing` is one axis, and "not yet looked at" is the absence of a position
on it, which is why it reads as a section rather than a standing.

Two consequences. Filing is not a conveyor — an entry can leave `## Unfiled`
straight into an `observed` claim of its own, because *this one is already
confirmed* is a judgement the pass can make and the jot cannot. And if the pass
never runs, everything sits unfiled, which is precisely the ledger as it stood:
the failure mode is today's behaviour rather than a worse one. It stays a
section and not a second file; the only argument for splitting is `open.md`
growing unreadable, and at that point a heading becomes a file for free.

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
