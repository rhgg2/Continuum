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

2. The document reads linearly. Each sentence follows logically and
   without external context from everything that precedes it.

3. When any part of it is superseded, delete the part. Do not record
   the change; replace the old model and let the new one stand alone.

4. Do not relitigate the path not chosen. We are only interested in the
   path we are going to take.

5. A heading that names a refutation, and a preamble inventorying what
   was tried and discarded are two shapes this failure takes.

## The register

1. The tone is analytic, dry, sparse, but always clear.

2. Every sentence makes a claim. The test is to delete it; if only the
   tone changed, it was ornament.

3. For a sentence that earns its existence, prefer the phrasing that
   expresses it most vividly.

## Nomenclature

1. Assign specific meanings to terms; state those meanings before using
   them; do not allow them to wander.

2. One word names one thing. A word doing double duty is two words.

3. Be parsimonious with imported vocabulary: an elementary formulation
   that carries the idea will always be clearer.

4. Bold marks a term where it is defined, and a document's opening
   thesis. It marks nothing else. Italics carry emphasis.

## Structure

1. Each idea has one home. Cycling back to the same idea again
   undercuts the clarity of the prose.

2. The document is structured in sections, paragraphs, and sentences.

3. One concept per section. If a section weaves several threads
   together, separate them out and rewrite.

4. Lead a section with its central claim. The support follows.

5. Do not enumerate in a heading or a lead sentence. "The five slots"
   and "three properties arrive together" are obligations to maintain.

6. A section's paragraphs are a numbered list.

7. One idea per paragraph. If an idea needs more than a couple of
   sentences to say, it is two ideas.

8. A paragraph may contain a list. A list's items are all the same
   kind of thing. 

9. One claim per sentence.

10. All citations are to `§ <section>` only. Hence, paragraph
    renumbering is free.
