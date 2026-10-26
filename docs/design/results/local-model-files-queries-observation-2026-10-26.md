# Local probes — typed values, binary storage, queries, observation and recovery

Status: **accessory exploration, paused** after the maintainer clarified that
current work must establish supported NSPersistentCloudKitContainer sharing
feasibility, not reverse-engineer Core Data. These observations create no sharing
acceptance gates or additional required investigations.

Retained scope: bounded direct-framework observations on the current Mac, before any
GraphEvo 2 API or architecture selection. These are partial V04–V08 checks in
[the execution register](../graphevo-2-test-checklist.md), not cloud verification.

## Reproduction and environment

The standalone demo package `Experiments/DocumentProbe` imports Foundation,
CoreData and, in recovery tests, CryptoKit. It compiles in Swift 6 language mode
with complete concurrency checking. Managed objects remain on their context
queues; consumers receive immutable Sendable values. No unchecked Sendable or
preconcurrency import suppression was added. The fetched-results delegate's
MainActor assumption is explicitly limited to its constructed main-queue context.

Run `swift test --package-path Experiments/DocumentProbe`. Hardware/runtime:
current Mac, macOS 27.0.1 (26A434), arm64, Xcode 27.1 (27A9275), Swift 6.4
(`swiftlang-6.4.0.34.1`). Declaring macOS 12 in the package is not testing that
runtime or iOS. No CloudKit account, physical iPhone/iPad or normal demo state
was used. Generated stores were scoped to unique temporary fixture directories.

| Source stage | Commit | Source SHA256 | Suite outcome |
|---|---|---|---|
| Typed/file/query primitive checks | `53c1149` | `4c9fb19f23e15b58cd9642993afa072d4711f1c25a77c4e909b75d980c76b3df` | 7 tests, zero failures |
| Native observation comparisons | `fe11bde` | `eefd217d2900ed4f349f67ae866381db174f9b60e75789a92aefd926feb1ac7b` | 11 cumulative tests, zero unexpected failures; dependency gap observed |
| Recovery comparisons | `e6302d8` | `2999775f562c44580e0c7c91282d9780f31e3818930a246624ae0e9983a72dff` | 15 cumulative tests, zero unexpected failures, **one known failed guarantee** |

Hashes append each sorted repository-relative source path then its file bytes,
without separators, for the package manifest and all package Sources/Tests Swift
files. Exact file inventories and logs are retained in local GraphEvoLab archives
`2026-10-26-document-local`, `2026-10-26-document-observation-local` and
`2026-10-26-document-recovery-local`. The final count includes earlier tests;
do not add 7 + 11 + 15 as independent coverage.

## V04 — one application-model mapping candidate

A small ordinary application value conforms to a fixed-shape `DocumentModel`
protocol and maps to/from `DocumentValue`, without dynamic-member access.
Identity, graph, optional title and integer rank round-tripped. One application
model rejected an absent title while the underlying stored value remained valid;
that decoding error propagated rather than manufacturing a default. A parent
relation round-tripped and native nullification removed the child's reference
when its parent was deleted. The candidate write path rejected a cross-graph
parent and rolled back the attempted row.

This is a protocol-shaped example, not a generic schema or final signature.
It does not cover all scalar/heterogeneous property types, GraphEvo entity/edge/
action facades, application identity reconciliation, arbitrary cycles or a
scoped model lifetime. Its graph guard is application code, not a CloudKit
security guarantee.

## V05 — binary storage and closed backup

The model has an optional binary attribute with external storage permitted and
explicit filename/content type. Core Data chooses the physical representation;
tests neither infer externalization from size nor expose its private paths.
A 10 MiB fixture round-tripped byte-for-byte after closing and copying the entire
fixture directory, including any managed external content. Small (512-byte) and
1 MiB replacement fixtures exercised replacement, deletion and explicit rollback.
A deliberately missing filename in a saved row produced a decoding error.

This establishes the exercised local lifecycle and closed-directory copy only.
No cloud attachment transfer, streaming, selective download, file progress,
eviction, cancellation, live backup, peak-memory measurement or universal file
size guarantee was tested. Test duration includes fixture generation and is not
a transfer benchmark.

## V06 — native query primitives and pagination semantics

Tests executed a relationship predicate (`ANY children.title`), graph-scoped
count, integer sum and dictionary projections through native requests. Immutable
results were constructed inside the private context. Deterministic rank/identity
keyset pagination handled tied rank values without repeating previous rows.

An intervening insert before the cursor was intentionally absent from later
pages and present in a new whole query. This is moving-current-state pagination,
not a frozen snapshot or protection against arbitrary sort-key edits. Large-data
costs, memory/object counts, cycle/depth traversal, unsupported expressions and
remote-import visibility remain unmeasured.

## V07 — observed state versus event processing

A separate native NSFetchedResultsController observed actual background saves
through a main-queue context. Direct insert/value/order/deletion results updated.
Cancellation of a stream consumer stopped the delegate bridge; resubscription
fetched current data. A capacity-one newest-state buffer retained the latest
array while eleven publications produced ten dropped buffered batches. That is
explicit state coalescing, not durable or exactly-once event delivery.

The dependency check retained a counterexample: a parent matched a predicate on
its child's title. After only the child title changed, fresh SQL returned zero
parents, while the existing fetched-results controller still held one parent
and had published only its initial snapshot. This remained the observed state
after 25 ten-millisecond sampling intervals and local queue processing. The
comparative test records this result without silently refetching to repair it.
A green comparator does **not** mean dependency invalidation was satisfied.

This supports keeping dependency invalidation explicit in the observation
requirements. It does not establish that every runtime/controller configuration
has this limitation or that a later callback is impossible. Cloud delivery,
persistent-history replay and the future Watch API remain separate decisions.

## V08 — open errors and original-file preservation

With automatic migration disabled, an incompatible native model returned
`NSCocoaErrorDomain:134100`; the original model reopened the retained logical
row. A non-directory parent returned `NSCocoaErrorDomain:258`, preserved its
sentinel bytes and created no replacement store at another path.

Both a rejected incompatible native open and direct metadata inspection with
`NSReadOnlyPersistentStoreOption` changed the `.sqlite-shm` sidecar on this
runtime; the database and other fixture family members remained byte-identical.
The original expectation that read-only metadata inspection changes **no** file
failed. Its initial failing and diagnostic runs remain archived; the final test
retains the failed expectation as a named known issue rather than hiding it or
calling the guarantee satisfied.

A **separate** candidate copied the complete closed fixture directory and read
metadata only from that copy. It detected the model mismatch and preserved every
original file digest. This demonstrates that particular closed-copy path, not a
live-store backup or mandatory GraphEvo implementation. No v1 store-opening code
was changed and no conclusion about v1 data loss follows from these framework
comparisons. Account/cloud failures, interrupted operations, transitions and
downgrades remain open.
