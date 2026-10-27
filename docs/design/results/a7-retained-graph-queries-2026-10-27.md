# A7 — bounded typed queries on a retained native graph

Date: 2026-10-27. Read the [A7 contract](../graphevo-2-queries.md) and
[reader procedure](../../../Experiments/A7NativeProbe/README.md).

## Physical reader

The owner iPad (iPadOS 27.0) reopened the original private/shared files of A5 run
`413B4030-89B7-4C69-BAD6-55B6BD7DDC2D`. A retained its eight application nodes
(three Entity, three Relationship, two Action); B retained its original five
nodes, including two Entity objects of the same persistent type as A's.
The authorized Development container remained
`iCloud.com.valerioburiani.GraphCKDemo`.

The disposable demo linked the working A7 source with Xcode 27.1 / Swift 6.4.
The one-use `a7-queries.txt` reader ticket was reserved before native opening.
There was no application reseeding/edit, invitation, acceptance, share creation,
reset or replay. Native opening can perform ordinary bookkeeping/imports; this
is not an immutable-file inspection guarantee. The source demo/settings remained
untouched. No transport payloads, stores or raw native logs enter Git.

The reader observed:

- Successive filters combined with AND, selecting only the expected original-tag
  Entity whose label starts with the literal prefix. A count was three, B two;
  same-type objects did not leak across logical graphs.
- Relationship subject and Action object predicates each matched the expected
  two rows. An outgoing-related-node predicate matched two Entity objects.
- Projection returned three label rows; integer sum returned seven with one
  contributing row.
- Sorted label pages returned one then two distinct Entity IDs, with no
  remaining cursor.
- Breadth-first traversal of outgoing edges returned the two expected distinct
  neighbors at depth one, without revisiting the cycle's origin.
- A reference to B in an A query was rejected. A native candidate allowance of
  one was rejected without returning partial rows.

The filtered read reported 31 native candidates across the open resources,
eight scoped application nodes, 643 charged payload units and 16 evaluation
steps. These are logical execution diagnostics, not latency/memory measurements
or a SQL selectivity guarantee. File representation costs were not evaluated.

The physical reader used evolving pre-commit source; later nullable-string
semantics/enum-conformance adjustments are covered locally/CI, not claimed as a
second physical run. Only this retained local fixture/device was read. This is
not fresh cloud recovery, cross-account query execution, live observation,
durable history processing or a production envelope certification.

## Local and consumer validation

The full local macOS suite passed 450 tests: 322 legacy, 56 runtime, 51 store
and 21 model. New tests cover explicit AND/OR/null/literal-string semantics,
relationship/action/cycle scoping, bounded BFS, tied keyset pages and deleted
anchors, moving-current-state insertions, projection/count without application
decoding, pending mutation views, candidate/payload/work refusal, unsupported
operands before inventory, exact Int64 comparisons, overflow, heterogeneous
ordering, SQLite close/reopen, exact candidate threshold, scope-internal
cancellation and cancellation after evaluation begins. The independent Swift 6
consumer builds and runs typed filters/count/projection on SQLite.

The capability is explicit bounded inventory plus memory evaluation. Native
indexes, native COUNT/dictionary projection, grouped aggregates, durable cursors
and performance certification are not inferred. Schema/API consolidation and
mandatory migration remain open. A8 must separately establish dependency
invalidation, coalescing, cancellation and state-versus-processing contracts.
