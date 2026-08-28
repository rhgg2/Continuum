# Style

The register the project's prose is written in. This governs prose
written to be read:
- `docs/<file>.md`;
- `design/<doc>.md`;
- `design/decisions.md`;
- a plan's Queued lines.

Where a document disagrees with this style guide, the style guide
always has authority.

Implementation briefs are excluded; they are compressed by design. For
annotations and inline comments, see `docs/CONVENTIONS.md`.

## What a document is

1. A document is a statement of the current model.

1. It says nothing about what the model is not, or what it does not
   do; the exception is the "Open" section of a design doc.

1. It reads linearly, with each part following logically from its
   predecessor, and cross-references only other project docs.
   
1. Anything another doc holds is cited, not restated. What does not
   change is left un-enumerated.

1. Edits replace, rather than augment; paths abandoned do not retain a
   write-up.

1. A design doc states the model as it will be, in the present tense.

## Register

1. The tone is analytic but always clear. Words earn their place by
   making claims or by making them concrete.

1. There are no rhetorical flourishes: anything which changes only the
   tone should be deleted. 
   
1. Inanimate objects or abstract concepts are not actors: they are not
   personified or anthropomorphised. Standard technical idioms such as
   "the function calls", "REAPER writes" or "the API accepts" are ok,
   but not "REAPER knows", "the function charges" or "the API asks".

## Structure

1. One concept per section, and one section per concept. A section
   starts with its central claim, and the support follows.

1. Within a section, one idea per paragraph; an idea needing more than
   a couple of sentences should be two ideas. 
   
1. Paragraphs within sections are numbered; use markdown autonumbering
   (1., 1., 1.) so that reordering is free. 
   
1. A paragraph may contain a list, all of whose items are the same
   kind of thing, and which holds parallel data rather than reasoning.

1. Within a paragraph, one claim per sentence. Such subordination as
   there is goes one level deep, and usually as an apposition set off
   by dashes.
   
1. Terms are assigned specific meanings. Term definitions are bolded,
   as is a document's opening thesis. For any other emphasis, use
   italics, and sparingly.

## Diction

1. Connectives to avoid: furthermore, importantly, crucially, notably,
   significantly, additionally, ultimately, that said, it is worth
   noting, first and foremost, in conclusion.

1. Ones to prefer: however, thus, in fact, in particular, for example,
   indeed, while, yet, now, of course, namely, it turns out that, on
   the one hand … on the other.

1. Approval is generally mild with no hype — *pleasant*, *smoother*,
   *nice and general*; disapproval likewise.

1. Avoid coined compounds: *content-reconciled*,
   *park-then-recognise*, *fill-recognition*.

1. Avoid *A rather than B*, and *it's A, not B*.

1. Prefer plain constructions to elevated ones. Avoid cleft
   constructions and Latinate absolutes. If it sounds like the King
   James Bible, rewrite. So, *the box measures root fusion* rather
   than *what the box measures is root fusion*.
