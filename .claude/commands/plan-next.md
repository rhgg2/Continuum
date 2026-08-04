---
description: The planning step the plan's state calls for — split the in-flight phase into a queue, or compile the next queued item into an implementation brief.
disable-model-invocation: true
---

Two jobs live behind this command, and the plan's state decides which
one runs: filling Queued with commit-sized items from a stretch of the
design doc, and compiling the next of those items into a brief. Exactly
one of them can fire at any given point, which is why they share a
command — the guard that picks between them used to be written twice,
once from each end.

**One job per invocation, then stop.** Filling reads the design doc at
phase scope — or, in a phaseless plan, whole-doc scope — and produces a
shape for that whole stretch; compiling reads code and produces one
implementable brief. They are different kinds of reading, and running
them back to back lets each bend to the other — the split sized to suit
a brief already half-written, or the first item sized to whatever the
split found convenient. The stop is also where I read the new queue and
object, before a large search commits to the shape of its first item. So
a run that fills Queued does not go on to promote from it.

## 1. State

The live plan and the brief's existence arrive injected by the
`UserPromptExpansion` hook — work from those rather than re-reading
them. (A plan or brief over the 10k context cap arrives as a file path
and a preview; read the path.)

The plan file is a working buffer, and its sections are what the
dispatch below reads:

- **Phases**, where the plan has one, is my map; it changes only when
  the roadmap does. No Phases section means a phaseless plan, whose
  scope is the whole design doc and whose Queued is seeded once.
- **Queued** holds the incomplete items of the in-flight phase, or in a
  phaseless plan the remainder of the job.
- **Now** names the item being implemented, in one line, and points at
  the brief.
- **Landed** prunes below ~4 entries — git and the design doc's dated
  notes are the permanent record.

The brief itself is `plan/IMPL.md`: untracked, one item, written here,
consumed by `/implement-next`, deleted by the landing bookkeeping.

## 2. Dispatch — first match wins

1. **A brief exists.** The last compiled item hasn't landed, so neither
   job runs: say so and stop, pointing at `/implement-next` to finish it
   or at `/commit` to land it. Overwriting `plan/IMPL.md` would drop a
   brief that exists nowhere else.
2. **Queued is non-empty.** Compile its top entry — § 3. This holds
   whether or not the plan has phases, and it is why splitting never
   fires here: refilling mid-phase would re-decide items already sized,
   and the later ones are the ones the earlier ones' landings inform.
3. **Queued is empty and work remains unqueued.** Fill it — § 4. Two
   ways to be here, and they are the same job at different scopes: the
   plan has Phases and the `← in flight` marker is not on its last
   entry, so the next phase's section gets split; or the plan is
   phaseless and Landed is still empty, so it has never been queued and
   the whole doc gets seeded.
4. **Queued is empty and everything has been queued.** The work is
   finished: say so, point at `/plan-close`, stop. Phased, that's the
   marker sitting on the last entry; phaseless, it's Landed holding
   something — a phaseless plan is seeded exactly once, so an empty
   queue after anything has landed means the job is done.

## 3. Compile the top queued item

1. Size check — three duties, before promoting:
   - **Commit-sized**: one landable change, spec included. An item
     that is really two or more commits gets split into ordered Queued
     lines; promote only the first.
   - **≤150k context**: the brief must name tight file/line ranges so
     an implementation session works from the brief plus those ranges
     alone. If it can't, split further.
   - **Tree-runnable evidence**: any measurement that gates the item's
     landing must come from a command runnable from the tree — an
     existing tool, a spec, the suite. If the completion test would
     have to be *built* to be stated, the harness is its own Queued
     item and lands first; a scratchpad differential dies with the
     session that built it, so it can inform but never gate.
2. Study before proposing anything: the relevant sections of the design
   doc named in the `> source:` line, plus the relevant code (maps
   first), until you could implement the item without the doc. The
   search is the expensive part — finding an 80-line seam in a
   5,000-line module costs an order of magnitude more than stating
   where it is — and the brief is its memo.

   The scratchpad and spike worktree settle *design* questions here —
   a fork you can name before writing the code, whose answer changes
   what the brief says. The overreach test: if stating the completion
   test requires building it, stop — a brief that predicts the
   build's results makes this session the second owner of the
   implementer's work. That finding changes the item's shape, not
   just its brief: queue the harness as its own item (step 1) and
   re-size. The brief's anchors and shapes come from reading;
   certainty beyond that is the implementation session's to earn.
3. Bring the search to chat: what the item turns out to involve, the
   forks the search exposed, what you'd do, what you're unsure of.
   Anything the design doc left open is settled here too — the brief
   records the settlement, the design doc gets the dated note. That note
   is prose and follows `docs/STYLE.md`; the brief is not, because it is
   executed rather than read.
4. Once we're ready and I have said go: write the settlement up as
   `plan/IMPL.md`. If something else comes up while writing, let's
   settle it together; bring it back to chat. The implementer gets the
   brief and nothing else — not this conversation, not the plan file,
   not the design doc — so it has to stand alone:
   - what and why, briefly;
   - the decisions already settled — each carrying the reason it went
     that way, and, where one exists, what would overturn it. A bare
     instruction can only be complied with or not; a reason can be
     found false, and that is the only way an implementer meeting a
     surprise can tell a stale premise from a detail to absorb. The
     shape:

     ```markdown
     **Bare names, not result rows.** A `src:line @kind head` row is
     ~10× a bare name, and the modules in this population are the three
     largest in the corpus. *Reopens if* the names turn out to need
     their line numbers — the symptom is <what you would see>.
     ```

     Not every decision has a defeater; where there is none, omit the
     clause rather than inventing one. This is a register for the
     judgements only — anything naming an observable outcome ("zero
     removed lines across all 44 maps") stays imperative, because that
     is a check the implementer runs and gets a result back from rather
     than an instruction to obey;
   - target shapes (data structures, fields) copied in, not pointed at;
   - file anchors — tight ranges, current line numbers (the plan will
     be implemented immediately, so no worries over drift);
   - red-spec-first when the item fixes observable behaviour, naming
     the target spec file and fixture;
   - what done looks like: suite green, plus the item's own evidence
     as observables and directions — which measurement moves, which
     way, and the tree-runnable command that produces it. Numbers
     have one owner: the run the implementer makes. Sizing gathered
     during the search may be stated as sizing, marked as such; it
     is never a gate.

   It opens with a header, so a session that has only the brief can
   still locate itself:

   ```markdown
   # <item title>

   > plan: `plan/<slug>.md` · source: `design/<doc>.md` § <section>
   >
   > Untracked working file — `/plan-next` writes it, `/implement-next`
   > works from it, the landing bookkeeping deletes it.
   ```
5. Stage the brief and the plan-file update as one `apply_patches`
   call: the brief as a create with `overwrite: true` — there is no
   anchor to match, and the dispatch has already established nothing is
   being lost — and Now replaced by a single line naming the item and
   its design reference.

   ```markdown
   **Teach `usedby` the intra-file `@call` index** — brief in
   `plan/IMPL.md`. (design § Intra-file call edges)
   ```

   The title thus lives in two places, which is the one duplication
   here and is deliberate: the tracked plan has to answer "what is in
   flight" for a cold session, for a park, and for a human reading git.
   Both copies are written by this call and both are removed by the
   landing, so they never diverge in between.

## 4. Fill Queued from the design doc

1. Phased plans do the Phases bookkeeping first, since it decides which
   section you're about to split: the in-flight phase's last item has
   landed, so mark that phase landed in Phases (dated, with the commit
   count if it took several) and move the `← in flight` marker to the
   next phase. The dispatch established there is one. A phaseless plan
   skips this — it has no marker, and its scope is the whole doc.
2. Split that scope into Queued: ordered one-liners, each a landable
   change with its spec, each carrying the *what* in enough detail that
   § 3 can compile a brief from it without re-reading the whole section.
   Order by what the next item needs to exist already. Prefer the split that makes each line
   separately reviewable over the one that makes them equal in size.

   Write them in plain sentences — the prose register of
   `docs/STYLE.md`, not the compressed register the briefs use. Queued
   is what a cold session and I both read to see what is coming, and the
   compression buys about a third of the length at several times the
   cost in readability.
3. If the split exposes a decision the design doc leaves open, settle
   it with me before writing the queue. The Queued line records the
   settlement in passing; the design doc gets the dated note.
4. Stage the plan update as one `apply_patches` call, then stop. Don't
   promote the first item yourself — the head of this file says why.
