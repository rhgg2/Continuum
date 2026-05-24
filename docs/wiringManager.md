# wiringManager

Persistence + validation seam for the wiring page. The page edits
through wm, wm gates writes through `DAG.validate`, persists to cm.
For the graph model itself see `design/wiring.md`.

## One project-tier cm key

The user graph is `{ nodes, edges, _nextId }` — a small structured
value with internal cross-references. Storing nodes and edges in
separate cm keys would open a window where a partial load can yield
an edge pointing at a node that hasn't been read in yet, and where
the `_nextId` allocator can desync with the node table. One blob,
one load, one write — `wiringGraph` is welded.

## The mutate transaction

Every authoring gesture funnels through `wm:mutate(fn)`:

1. clone the current graph into a draft
2. caller mutates the draft
3. `DAG.validate` checks the result
4. on pass — swap, persist via cm, emit `wiringChanged`
5. on fail — return `false, err`; in-memory state and on-disk state
   are both untouched, no signal fired

Clone-then-validate-then-swap means a bad mutator (or a logically
inconsistent intermediate state during a multi-step edit) never lands
on disk and never broadcasts a corrupted graph downstream. The Stage 2
differ subscribing to `wiringChanged` can assume validation has
already passed.

## Master is a regular node

The master sits in `graph.nodes['master']` with `kind='master'`,
materialised by `freshGraph()` on first load of an empty project.
Not a special parallel field. The singleton constraint is enforced
by `DAG.validate` — same mechanism that would catch a buggy mutator
minting a second master, rather than two storage shapes encoding the
same rule.
