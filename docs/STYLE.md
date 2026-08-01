# Style

The register the project's prose is written in. `docs/CONVENTIONS.md`
governs the layers — what belongs in an annotation, what belongs in a
doc; this file governs the sentences.

`docs/tuning.md` is the worked example. The rest of `docs/` converts
as it is touched, so this file describes where the prose is going
rather than where it is.

## What it is

**1** The tone is that of Anglo-American analytic philosophy, with a
touch of Wittgenstein and of late Eliot.

**2** The analytic inheritance is the bulk of it: a distinction drawn
sharply and then named; the wrong view put in its strongest form
before it is dismantled; a criterion given as a criterion.

**3** From Wittgenstein, we take the numbered remark — applied
lightly, as sequential numbering within subsections, and nothing more.
We also take the imagined interlocutor who holds the tempting view, so
that the text answers someone instead of asserting into air. We do not
adopt his aphoristic withholding, which would be fatal here.

**4** From late Eliot comes cadence: abstractions that narrow to the
plain and concrete, rather than trailing off into further abstraction
— *the wire cannot remember why anything is on it.* 

## What this governs

**1** Prose written to be read: `docs/<file>.md`, `design/<doc>.md`,
the dated entries in `design/decisions.md`, and a plan's Queued lines.
These are the surfaces where a reader arrives cold and has to
reconstruct something, which is what the register is for.

**2** The implementation brief is the exclusion worth stating: a brief
is compressed by design, being consumed once only, and immediately, by
one about to act.

**3** Annotations and inline comments answer to `docs/CONVENTIONS.md`
instead. Their discipline is one of length and pre/post conditions.

## The register

**1** Five devices allow us to describe a model vividly:

- **Ask questions before giving the answer.** A section that opens
  with its conclusion leaves the reader unmoored. By spelling out
  which two things get confused, what the code has to decide, or what
  goes wrong without the rule, the verdict is charged with
  inevitability.
- **Name the wrong view first.** We assume the reader arrives holding
  the tempting-but-wrong reading. Left unnamed, the correct account
  has to displace it silently, but may not. Naming the trap accounts
  for *why* the rule has the shape it has.
- **One claim per sentence.** Three claims joined by semicolons and
  em-dashes are all present and arrive too fast to be taken. The facts
  survive the split; only the density is lost.
- **One idea per paragraph.** The same rule one level up, and §
  Paragraph numbering is how it is held to.
- **State a criterion as a criterion.** "Fake in virtue of its
  provenance, not its constitution" does not give up meaning from its
  concision; it tells the reader what to check.

**2** These devices suit best those sections carrying a **model** — a
lifecycle, an ownership rule, a transform, a distinction that gets
confused. Other section-types may find less use for them; thus, an
inventory of mechanisms has no question worth staging, and the setup
sentence becomes padding. Judge per section, not per file.

### Paragraph numbering

**1** A section's paragraphs are numbered from **1** in bold, flat,
restarting at each heading. The number is a commitment: three ideas
can hide in an unbroken paragraph and they cannot hide in one wearing
a number. So the numbering is not decoration on the pacing, it is the
mechanism of it.

**2** It also buys intellectual breathing-space. A numbered paragraph
has somewhere to stop, so the next idea begins in its own domain, not
annexed to the end of the last one. 

**3** Paragraph numbers are not addresses. Everything citing a doc
from outside — source comments, specs, other design docs — cites `§
<section>`. Thus, renumbering within a section is free, while changing
aheading is not: it pulls `.lua` files and a map regen into what would
otherwise be a docs-only change.

## Ornament

**1** Every sentence should do work. A beautiful sentence whose beauty
expresses no claim does not pass scrutiny. The simple test is to
delete the sentence; if only the tone changed, it was ornament.

**2** This is not to require that every sentence be plain. A claim
carried beautifully is optimal rather than acceptable. Thus, between
two phrasings of a claim that has to be made anyway, prefer that which
expresses it most vividly.
