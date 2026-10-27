# GraphEvo 2 — A7 bounded typed queries

Status: alpha implementation candidate. Read with section 9 of the
[specification](graphevo-2-specification.md), [typed stores](graphevo-2-typed-store.md)
[A6 attachments](graphevo-2-attachments.md) and the
[retained results](results/a7-retained-graph-queries-2026-10-27.md). The native schema and stored
layouts are unchanged. A7 is initially stacked on A6 PR #75; its temporary PR
base is `codex/v2-native-files`. Retarget to `codex/graphevo-2` after A6 is
reviewed/merged. No A6 merge is implied by this stack.

## Descriptor and execution contract

```swift
let budget = try GraphQueryBudget(maximumCandidates: 2_000)
let query = GraphQuery<Person>(budget: budget)
    .where(.tag("active"))
    .where(.property("score", .greaterThanOrEqual, .integer(10)))
    .sorted(by: [GraphQuerySort(.property("score"), direction: .descending)])
    .limit(20)
let result = try await graph.query(query)
let count = try await graph.count(query)
let fields = try await graph.project(query, properties: ["name", "score"])
let sum = try await graph.aggregate(query, .sum("score"))
```

A descriptor fixes the persistent model type/kind and an explicit Boolean
expression. Successive `where` calls combine with AND. OR/NOT require explicit
expressions. This differs from the retained v1 Search API, whose successive
filters still combine with OR. Keys are literal persistent property names, not
Swift key paths, nested-object paths, predicate-format strings or wildcard
expressions. Strings use case-sensitive nonlocalized Swift comparisons; no
implicit case/diacritic folding is inherited from v1.

`GraphQueryResult<Model>` contains detached items, an optional next cursor,
local-view identity and execution diagnostics. Model decoding occurs only for
returned items; a decoding failure fails the entire typed result. Count,
projection and aggregation intentionally do not invoke application-model
initializers and do not certify domain/file-content validity.

All operations also exist synchronously on GraphReadScope/GraphMutation.
`GraphQueryLocalView` contains graphID, scopeID and includesPendingChanges. The
UUID identifies the current scope, not a native generation/token or timestamp.
The flag marks mutation-scope execution, whether or not a pending edit actually
exists. Operations inside one scope share that identity. SQLite read scopes use
the existing runtime query-generation pin; memory/transaction views retain their
existing semantics. No result implies CloudKit completeness.

## Explicit strategy and allowances

`explain()` validates the descriptor shape and returns one current strategy:
`boundedInventoryAndMemory`. Graph-specific cursor/reference validation happens
at execution before inventory. There is no hidden native-to-memory fallback,
SQL property-predicate translation, native COUNT or dictionary projection.
The current encoded-value representation does not provide those scalar indexes.

Callers must supply maximumCandidates. The defaults for other allowances are
32 MiB of charged property payload and 100,000 logical evaluation steps.
Native inventory fetches Entity, Relationship and Action rows with fetchLimit
and a one-row overage check. Candidate allowance includes all locally available
node rows in the open resource group, including other graphs, hidden membership
and staging rows. Only the requested graph's application records enter evaluation.
A budget is therefore not a result count or a promise of graph-selective I/O.

Before decoding typed property envelopes, the implementation charges user keys,
raw Data lengths, UTF-8 strings/type/unique tag-group names, and a small structural
allowance for legacy values/containers. Diagnostics expose propertyBytesCharged,
not physical store size or exact allocated bytes. All selected-graph records are
currently snapshotted, including nonmatching model types and attachment content.
This is visible work, bounded by the supplied allowance, rather than an implicit
optimization. Attachment storage/ownership remains unchanged; representation
costs will be assessed at the agreed end-of-alpha review.

Steps bound predicate visits, relationship/action inspections, endpoint visits,
ordering and aggregation work. They are logical work units, not CPU instructions
or a deadline. Metadata, opening/catalog work, existing context caches, property
extraction and caller model code are not a hard resident-memory bound. Exceeding
an allowance throws budgetExceeded with its dimension; no partial result escapes.
Cancellation is checked around native inventory, between records and periodically
inside evaluation. Native fetch/codec calls settle before the next check; no
instantaneous cancellation guarantee is made.

## Capability matrix

| Feature | Current contract |
|---|---|
| Type/kind/identity | Fixed by Model, optional type/id predicates; references must belong to this graph |
| Tags/groups/existence | Exact literal membership; existence distinguishes missing from explicit null |
| Boolean composition | AND/OR/NOT; empty AND is true, empty OR false; max 256 AST nodes/depth 32 |
| Equality | Null, Bool, Int64, UInt64, finite Double/Decimal, String, finite Date, UUID and URL; numeric cases are not coerced |
| Ordering | Same-case Bool (false first), integers, finite Double/Decimal, String and Date; heterogeneous ordered values fail |
| String operators | Literal contains/beginsWith; missing/null values do not match |
| Opaque/container data | Presence and projection only; Data/array/object/encoded comparisons and ordering are rejected |
| Missing/null | Missing comparisons are false, including notEqual; explicit null is a value for equality/inequality and does not match ordering/string operations |
| Sorting | At most eight keys: identity, createdDate or property; UUID ascending is the final tie-breaker |
| Missing sort values | Missing and explicit null share a bucket; first/last is independent of sort direction |
| Count | Full filtered set within allowances, ignoring order/limit; cursor rejected |
| Projection | At most 128 literal keys; ID retained, absent keys omitted, explicit null retained; order/page respected |
| Sum | Homogeneous Int64/UInt64/finite Double; integer overflow or non-finite result fails; Decimal sum unsupported |
| Minimum/maximum | Homogeneous ordered scalar values; missing/null skipped |
| Empty aggregate | Nil value and zero contributors; aggregation ignores order/limit and rejects cursor |
| Related predicates | Directed relationship or action-endpoint Entity neighbors, optionally filtered by exact edge/action type; existential and deduplicated per hop; at most four nested hops |
| Breadth-first traversal | Entity origins, directed relationship/action expansion, depth 0...32 and work allowance; excludes origins, never revisits nodes, orders by depth then UUID |

Properties not used by an expression may contain opaque values. Unsupported
operands/keys/descriptor shapes fail before inventory even in a dead Boolean
branch. Actual ordered-field types are validated before slicing the page,
including a single-row result. Integer comparisons do not pass through Double.
Floating sum follows deterministic UUID input order, not an exact arithmetic
or cross-platform reproducibility guarantee. Grouped aggregations, arbitrary
recursive predicates and unbounded traversals are unsupported.

Relationships/actions resolve only existing application Entity endpoints in the
same graph. Hidden root/membership links are not traversed. Optional absent
endpoints and empty actions do not create neighbors. Nested existential predicates
may revisit a node at a later fixed hop; BFS instead suppresses all revisits.
Attachment ownerID is a logical ownership field, not an implicit relationship
edge, so traversal does not reinterpret it.

## Current-state pagination

A positive limit bounds one page. A next cursor is returned only when more rows
remain. `query.after(cursor)` re-evaluates the current local view and compares the
stored last sort tuple/UUID; it does not look up the old anchor or use offsets.
A deleted anchor therefore remains usable. Insertions before the tuple are not
returned by later pages; sort-key edits can move/repeat/omit rows. This is not a
frozen multi-page snapshot or deduplication session.

The opaque Sendable cursor binds graph, model type/kind, predicate structure and
sorts. A changed descriptor or another graph is rejected. Changing page size or
work allowances is permitted. Fetch/projection may share the same cursor; count
and aggregation reject it. Cursors are in-memory values, not Codable portable
or durable continuation tokens. Independently executed pages have different
local-view identities. A count performed separately is not pinned to an earlier
page.

## Alpha boundaries

The local capability/semantics tests and separate retained iPad reader are not
cloud-delivery or observation evidence. Schema/index improvements, production
cost envelopes and attachment representation costs remain consolidation work.
A8 will reuse these descriptors for observation with explicit dependency
invalidation and slow-consumer/cancellation semantics; this increment adds no
watcher or processing-replay promise. V1 data migration remains mandatory, with
query AND/string/null/numeric differences recorded for application adaptation.
