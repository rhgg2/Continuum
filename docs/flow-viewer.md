# Flow viewer

`tools/flow_view.py` writes a self-contained page that renders one
declaration and expands each callee inline where it is called. The
tool's surface is in its docstring. What needs room here is the one
kind of edge the page draws that the maps do not hold, and what that
edge is worth.

## Nested locals

**1** A reader following a control path meets two kinds of callee. The
first is a declaration the maps hold — `@fn`, `@api`, `@held`,
`@handler` — reached by an edge the extractor recorded as it walked the
file. The second is a `local function` declared inside the body it
serves. For the second kind the maps hold nothing: not an unresolved
edge, but no edge at all, because the extractor records a call only
against a declaration it has. So `chrome.makeToolbar` shows no call to
`measureWidths`, and the seventeen lines of `measureWidths` sit in the
middle of the function that called it.

**2** The tempting repair is to call this a gap in the maps and close
it there. It is not a gap. A nested local has no module-qualified
spelling, so nothing outside its parent can cite it, and an index whose
question is cross-file reachability has no use for a node no other file
can reach. The viewer is the only consumer, so the viewer mints the
edge.

**3** Minting it means finding call sites by name — the one inference
in the payload not derived from something the extractor had already
computed. The criterion is lexical and deliberately narrow: a site
reaches a local only if it lies below that local's declaration line and
within the function the local was declared in, its own body included so
that recursion resolves. The rule does not model Lua's block scoping,
which would leave two locals of one name under one parent
indistinguishable; that case is declined outright rather than guessed,
and counted in the build report.

**4** The narrowness is not caution for its own sake. In `rebuildPbs`,
`replaceWindows` declares `inKeptRange` and returns it in a table, and
`deriveChan` rebinds it from that table a hundred lines further down. A
plain name match chips the rebound occurrence to the lexical
declaration. The scope rule declines it, because at that point the name
denotes a local variable, and its identity with the function is a fact
about values rather than about text. Thirteen of the corpus's sites are
that one pattern.

**5** The criterion has a second consequence, and it is a limitation
that shows on the page. A local that escapes its parent — returned,
stored in a table, passed as an argument — has no call site to be
found. Twenty-six of the corpus's two hundred and eighty-seven are of
this kind, `settleOnset` and `parkedBoundFor` among them, and each
renders as a definition with nothing pointing at it. The viewer can say
where a function is written; it cannot say where a value travels.

**6** What the lifting buys is measured on the function that motivated
it. `rebuildPbs` is 565 lines and renders as 142, or 108 with the
definitions hidden altogether. Every line it removes is one click away,
at the place that made the call.
