# Style

The register the project's prose is written in.

## What this governs

1. Prose written to be read: `docs/<file>.md`, `design/<doc>.md`, the
   dated entries in `design/decisions.md`, and a plan's Queued lines.

2. Implementation briefs are excluded; they are compressed by design.

3. For annotations and inline comments, see `docs/CONVENTIONS.md`
   instead.

## What a document is

1. A document states the current model. It says nothing about how that
   model was reached.

2. The document reads linearly. Each sentence follows logically from
   everything that precedes it. External content is scoped to
   cross-references to other project docs, and terms pulled in get a
   brief gloss before use.

3. When any part of the document is superseded, it leaves no trace of
   what came before. The document is not a historical record; the old
   model is removed and the new one stands alone.

4. The document does not relitigate paths not chosen. It is only
   concerned with the path that will be taken.

5. Thus, there are no headings that name refutations, or preambles
   inventorying what was tried and discarded.

## The register

1. The tone is analytic, dry, sparse, but always clear.

2. Every sentence and every clause in a sentence makes a claim. The
   test is to delete it; if only the tone changed, it was ornament.

3. For a sentence or clause that earns its existence, it adopts the
   phrasing that expresses it most vividly.


## Nomenclature

1. Terms are assigned specific meanings terms; state those meanings
   before using them; do not allow them to wander.

2. One word names one thing. A word doing double duty is two words.

3. Be parsimonious with imported vocabulary: an elementary formulation
   that carries the idea will always be clearer.

4. Bold marks a term where it is defined, and a document's opening
   thesis. It marks nothing else. Italics carry emphasis.

5. Definitions bear no preamble or preparation. They are stated
   flatly, and unpacked only when there is a non-obvious WHY.

## Structure

1. Each idea has one home. Cycling back to the same idea again
   undercuts the clarity of the prose.

2. The document is structured in sections, paragraphs, and sentences.

3. One concept per section. If a section weaves several threads
   together, separate them out and rewrite.

4. A section starts with its central claim. The support follows.

5. Heading and lead sentences carry no enumerations. "The five slots"
   and "three properties arrive together" are obligations to maintain.

6. A section's paragraphs are a numbered list.

7. One idea per paragraph. If an idea needs more than a couple of
   sentences to say, it is two ideas.

8. A paragraph may contain a list. A list's items are all the same
   kind of thing. 

9. One claim per sentence.

10. All citations are to `§ <section>` only. Hence, paragraph
    renumbering is free.
