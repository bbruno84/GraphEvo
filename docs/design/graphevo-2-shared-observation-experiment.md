# C04a — shared observation refresh experiment

Status: local matrix and confirmation measured; opt-in laboratory after #82 (`ed1a430`). Default observe,
publisher, change signals, schema, budgets and native invalidation remain unchanged.
Use the default current model, not C02b's native identity model, to isolate costs.

This document describes the retained experiment checkpoint. PR #83 was reviewed
and merged into its experiment parent on 2026-10-29 (`9232993`); exact-head CI run
`40575201851` passed. The subsequent public-path implementation is specified in
the [C04 adoption contract](graphevo-2-observation.md#c04-consolidation-adoption).
It does not retroactively change the measured checkpoint or close native gates.

## Candidate and contract

One explicit GraphSharedObservationLab belongs to one GraphStore handle. Share
only structurally equal validated first-page descriptors: concrete Swift model
type, graph type/kind, predicate, ordering, limit and every budget dimension.
Different handles/graphs/models/budgets do not share. There is no global registry,
last-result replay or persistent cache. A join requests a new read and cannot
receive a read that started before its registration. Native source registration
precedes returning from subscribe. Account changes end the group with a visible
failure; close ends the owning handle's groups, not sibling handles.

One native query produces immutable records/local view, then each subscriber runs
its application decoder on an independent worker with its own newest-input buffer.
A slow decoder does not run on the shared native-refresh worker. A decoder failure is subscriber-local;
native query failures are visible and can recover on the next broad invalidation.
Per-consumer newest-state buffering, cancellation and Combine demand remain.
The last consumer retires/cancels its worker and native source. Callbacks and
application-value destruction never run under a coordinator lock. Only detached
Sendable values cross tasks. Observations retain their existing graph handle as
before; no additional lease, native context or managed object is cached.

This first candidate retains broad invalidation for relationships/actions/files,
store notifications and refresh. It does not attempt dependency-based suppression,
cross-handle sharing, per-node events or durable processing. Consumers of the same
execution share scopeID/diagnostics (one actual local read), not a fabricated view
per delivery. Diagnostic execution counters count work, not delivered mailboxes.

## Matrix

| Check | Evidence |
|---|---|
| Equivalence | Two equal descriptors share scopeID on explicit refresh; different filter/order/limit/budget/model/handle/graph remain separate |
| Local state | Other-handle edits, relationship/action endpoint/tag changes, order/limit movement, file replacement, deletion and newest-state rescan |
| Failure | Native query failure and recovery; per-consumer decode failure; account switch during a read; closed-handle admission |
| Lifetime | Individual cancellation/drop, cancel/join races, last-consumer cleanup, late join during an in-flight read, handle close and sibling survival |
| Combine | Cold demand starts subscription, independent cancellation/demand, shared native work through the unchanged Combine adapter |
| Cost | Fresh Release processes; same seed/source/layout; 1/8/32 equal and mixed queries, scalar and file-bearing graphs; startup separate from update wave; native read counts, time and sampled whole-process RSS |
| Exit | Retain failed candidates/results; repeat representative cases independently; assess single-observer overhead and sharing gains before public integration |

Use bounded fixtures outside Git. Do not run timing beside builds/tests or compare
silently different storage/query/validation contracts. CI functional smoke uses no
latency threshold. Synthetic/native notification tests are not cross-account
CloudKit evidence. Native synchronization, representative workloads and all
post-alpha migration/schema/observation gates remain open.

The first implementation decoded each recipient sequentially on the fan-out
worker. Before timing, it was changed to independent per-subscriber decoding
workers so arbitrary application construction cannot block shared refresh. Both
bounded input and public output mailboxes are newest-only; there is no replay to
new subscribers. Refreshing one member can refresh all equal-descriptor members.
Source/callback checkpoints are injectable only for deterministic local tests.


## Executed result

The [retained comparison](results/c04a-shared-observation-2026-10-27.md) contains
300 full-matrix and 120 independent confirmation rows, plus both 12-row screens.
Exact-query update waves improve substantially; initial subscription, single and
mixed workloads do not gain comparable savings. Keep this as the candidate for
review, with broad invalidation and independent decoder workers. Public adoption,
heavy-decoder/slow-consumer envelopes, device-native account/import behavior and
all observation/schema/migration gates remain open.
