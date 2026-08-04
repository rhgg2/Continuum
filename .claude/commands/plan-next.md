---
description: Talk the next queued plan item through in chat; then compile to an implementation plan.
disable-model-invocation: true
---

This skill facilitates a conversation, with the next queued plan item
as its subject: what implementing it actually involves, what the
search turns up, and any wrinkles you can see. Once everything is
settled to our mutual satisfaction, you'll proceed to write up an
implementation brief.

Steps 1–6 below are preparation and chat; step 7 onward is the
write-up, and we only start it when we're both happy to proceed.

1. The live plan arrives injected by the `UserPromptExpansion` hook —
   work from that rather than re-reading it. (A plan over the 10k
   context cap arrives as a file path and a preview; read the path.)
   The plan file is a working buffer. Phases, where the plan has one,
   is the human's map; it changes only when the roadmap does. Queued
   holds the incomplete items of the in-flight phase, or in a phaseless
   plan the remainder of the job. Now names the item being implemented,
   in one line, and points at the brief. Landed prunes below ~4 entries
   — git and the design doc's dated notes are the permanent record.
2. The brief itself is `plan/IMPL.md`: untracked, one item, written by
   this command, consumed by `/implement-next`, deleted by the landing
   bookkeeping. So the hook reporting one already there means the last
   item hasn't landed — say so and stop, pointing at `/implement-next`
   to finish it or at `/commit` to land it. Overwriting it would drop a
   brief that exists nowhere else.
3. Queued is filled by `/plan-phase` (phased) or by `/plan-new`
   (phaseless); this command never refills it, because sizing a whole
   phase and compiling one brief are different kinds of reading. So an
   empty Queued means the level above needs to run: point at
   `/plan-phase` if the plan has Phases, or at `/plan-close` if it
   doesn't — a phaseless plan with an empty queue is finished work.
   Either way, say so and stop.
4. With Queued non-empty, the goal is to promote its top entry and
   compile it. Size check — three duties, before promoting:
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
5. Study before proposing anything: the relevant sections of the design
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
   just its brief: queue the harness as its own item (step 4) and
   re-size. The brief's anchors and shapes come from reading;
   certainty beyond that is the implementation session's to earn.
6. Bring the search to chat: what the item turns out to involve, the
   forks the search exposed, what you'd do, what you're unsure of.
   Anything the design doc left open is settled here too — the brief
   records the settlement, the design doc gets the dated note. That note
   is prose and follows `docs/STYLE.md`; the brief is not, because it is
   executed rather than read.
7. Once we're ready and I have said go: write the settlement up as
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
8. Stage the brief and the plan-file update as one `apply_patches`
   call: the brief as a create with `overwrite: true` — there is no
   anchor to match, and step 2 has already established nothing is being
   lost — and Now replaced by a single line naming the item and its
   design reference.

   ```markdown
   **Teach `usedby` the intra-file `@call` index** — brief in
   `plan/IMPL.md`. (design § Intra-file call edges)
   ```

   The title thus lives in two places, which is the one duplication
   here and is deliberate: the tracked plan has to answer "what is in
   flight" for a cold session, for a park, and for a human reading git.
   Both copies are written by this call and both are removed by the
   landing, so they never diverge in between.
