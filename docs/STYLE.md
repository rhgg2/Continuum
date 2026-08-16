# Style

The register the project's prose is written in. This governs prose
written to be read:
- `docs/<file>.md`;
- `design/<doc>.md`;
- `design/decisions.md`;
- a plan's Queued lines.

Implementation briefs are excluded; they are compressed by design. For
annotations and inline comments, see `docs/CONVENTIONS.md`.

## What a document is

A document is a statement of the current model; it reads linearly,
with each part following logically from its predecessor, and
cross-references only other project docs. Edits replace, rather than
augment; paths once taken and abandoned do not retain a write-up.

## The register

The tone is analytic but always clear. A sentence earns its place by
making a claim or by making one concrete; anything which changes only
the tone can be safely deleted.

Criticism is borne by understatement; one may say, "leaves a lot to be
desired", "has been found wanting", or "not as smooth as one would
like". 

## Sentences

Sentences may run long — thirty words is unremarkable — but do so by
coordination rather than subordination. Clauses sit side by side,
joined by semicolons, and each is internally simple. Such
subordination as there is goes only one level deep, and usually as an
apposition set off by dashes.

Rhetorical flourishes at sentence end are to be avoided; we think here
of needless intensifiers such as *at all*, *entirely*, *for good*,
*and nothing besides*, or an appended denial such as *it is long
because it houses tenants, not because it is tangled*.

## Concretion

An abstraction is typically followed by a concrete instance within a
sentence or two. Where the instance is small, it may come first and
the term arrive after it. A hard thing is introduced as a variant of
an easier one, where one exists. An analogy may be helpful, but is
stated as an analogy, and then dropped; it does not carry the
argument.

## Nomenclature

A term is assigned a specific meaning, and glossed in apposition where
it appears: *a groupoid — a category whose every morphism is
invertible*. Term definitions are bolded, as is a document's opening
thesis. For any other emphasis, use italics, and sparingly. 

## Structure

One concept per section, and one section per concept. A section starts
with its central claim, and the support follows.

Within a section, one idea per paragraph, along with anything that is
necessary to make the idea and its scope clear to the reader. A
paragraph may contain a list, all of whose items are the same kind of
thing, and which holds parallel data rather than reasoning.

Within a paragraph, one claim per sentence, except for the parallel
series of § Sentences, which take a single claim and distribute it.

## Diction

Connectives to avoid:

  furthermore, importantly, crucially, notably, significantly,
  additionally, ultimately, that said, it is worth noting, first and
  foremost, in conclusion.

Ones to prefer:

  however, thus, in fact, in particular, for example, indeed, while,
  yet, now, of course, namely, it turns out that, on the one hand … on
  the other.

Result may be carried by *so* and a participle: *so foreclosing an
entire avenue of enquiry*.

Approval is generally mild with no hype — *pleasant*, *smoother*,
*nice and general*.

Avoid coined compounds: *content-reconciled*, *park-then-recognise*,
*fill-recognition*. 

Prefer plain constructions to elevated ones: *gives it no uuid* rather
than *mints it no uuid*, *there is* rather than *there obtains*. A
first mention takes an indefinite article for the same reason: *an
intensifier propping up a claim*, rather than *the intensifier*.

A hedge is single and specific. "Appears to be new" is a hedge;
"might arguably perhaps" is a stack.

## Diagnostics

Symptoms, rather than rules; each is checkable against a draft.

1. A term named with no instance shown (§ Concretion).
2. Three consecutive sentences under fifteen words, or a third of a
   section below that length: the prose has gone aphoristic (§ Sentences).
3. A clause at the third level of nesting (§ Sentences).
4. An abstract noun standing where the verb it was made from would
   serve (§ Sentences).
5. A sentence closing on an intensifier or an appended denial (§ Sentences).
6. A bolded run-in that defines no term (§ Nomenclature).
7. A coined compound in every second sentence (§ Diction).
8. An archaic construction, or a definite article on a first mention
   (§ Diction).
9. A word from § Diction's proscribed list.
