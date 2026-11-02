# S04 native-sort capacity follow-up

Date: 2026-11-02. Base: `bf6b4ce` on `codex/graphevo-2`.
Scope: the 2,000-record refusal retained in the
[P03 report](s04-typed-properties-runtime-and-cloud-2026-11-02.md).

## Change and result

The native sorter previously scanned every nonempty fetch chunk for each emitted
row. The residual evaluator then comparison-sorted the merged ranks again.
The replacement uses a binary heap containing one head per fetch and passes the
ordered IDs directly to residual filtering. Heap comparisons, emitted IDs,
residual order reconstruction and cursor comparisons all consume the same
existing work counter. Ordering validation still precedes result limiting.
Duplicate order IDs and incomplete matching-record coverage are rejected.

No schema, persistent/cloud format, opening API, candidate/byte/step default,
predicate translation or property-integrity rule changes. Pending/in-memory and
unsupported sorts retain the existing evaluator.

## Retained Release experiment

The external P03 harness uses fresh local stores: 2,000 entities with the same
eleven properties, a 4-KiB binary property per entity and one owned 2-MiB asset.
The allowance remains 2,010 candidates, 32 MiB charged bytes and 100,000 steps.
Each variant runs five invocations of every existing query operation, retaining
complete-record, projection, count, sum, file, integrity and PH assertions.
Each seed/measurement uses a new store; failed sort requests are not replayed on
a modified fixture. Raw logs, stores and disposable bridges stay outside Git/CI.

| Implementation | Sorted page, five invocations | Outcome |
| --- | --- | --- |
| Integrated baseline query implementation | Five step-budget refusals | Reproduces P03 |
| Heap merge alone | Five step-budget refusals | Retained insufficient intermediate result |
| Heap plus direct reuse of merged order | Five complete successful pages | No budget refusals in any operation |

Final sorted-page samples are 392.60, 387.45, 394.37, 403.33 and 392.35 ms
(median 392.60 ms). These are one synthetic macOS Release fixture/process,
with uncontrolled caches and concurrent local verification work. They demonstrate
capacity at the existing allowance, not a production latency guarantee or a
performance ratio against the refused baseline. The earlier P03 refusal remains
historical evidence; disk/index, broad capacity and device envelopes remain open.

## Functional regression and review scope

A 2,000-record SQLite regression uses eleven properties and repeated rank values
across sixteen fetch chunks. Both directions and two pages reconstruct every
complete expected record with ascending UUID ties. An insufficient 30,000-step
allowance must still refuse without partial output. Fixture creation dates are
explicit, so ordinary insert-time date assignment is not mistaken for lost data.
This is a functional budget test, with no latency acceptance threshold.

Existing 300-record every-page tests retain small-page/cursor coverage. A detached
evaluator regression retains residual filtering, cursor continuation and rejection
of duplicate/incomplete order inputs. Final local checks pass 925 macOS functions
(331 legacy, 488 store, 76 runtime, 30 model), all three independent consumers,
manifest and diff validation. The reviewed CI checkpoint is recorded in
development status before integration.

No physical CloudKit protocol is repeated for this local query-only change.
P03's separate S04 sharing/asset/recovery evidence retains its original scope;
this result does not certify cloud migration, source acceptance or beta readiness.
