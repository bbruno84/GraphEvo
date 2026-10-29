# C04a — shared observation cost and correctness, 2026-10-27

## Scope and direction

The explicit package-only coordinator is a promising candidate for sharing exact
queries within one handle. Public observe/publisher, broad native invalidation,
default model, query budgets and integration/tag remain unchanged. This is local
experimental evidence, not production adoption or completed observation design.
Read the [contract](../graphevo-2-shared-observation-experiment.md) and
[runner](../../../Experiments/SharedObservation/README.md).

## Controlled comparison

Measured source: `d24d867987fbc8f95aac900577ebba6f3c463332`, default current model
at parent `ed1a430`; no C02b alternative model. A matched closed source is copied
for every fresh Release process. Five repetitions per case/observer count/query
shape/variant: 300 full-matrix rows and 120 independent confirmation rows on new
500-node and four-10-MiB fixtures. No failed stage was replayed. Builds/tests do
not run during timing; OS caches are uncontrolled. No product thresholds or
statistical confidence intervals are inferred from these small samples.

Cases: 100, 500, 2000 Entities, plus 100 Entities with four 1-MiB or four 10-MiB
owned files. Observers: 1, 8, 32. Equal queries select the changed Entity; mixed
queries select distinct Entities plus that common changed sentinel. Every delivery
must preserve its exact result identities, unchanged Entity revisions and the new
sentinel revision in a new local read view. A new scopeID alone cannot prove an
unchanged result read after the write. Budgets and complete-model decoding match.

Startup subscribes sequentially and awaits each initial result. Joins deliberately
queue fresh reads, with no cached replay; sharing cannot eliminate those reads.
The update wave includes one patch and all deliveries; write and remaining-tail
times are retained separately. CPU is process user+system time during that phase,
not wall time or whole-lifetime CPU. Concurrent native work can produce different
CPU and wall ratios; this does not make one native query intrinsically faster.

RSS is a 2-ms sampled whole-process peak including open/startup/wave/close, not a
query-only allocation measurement or guaranteed peak. Repeated deterministic file
patterns are not representative media/storage evidence. These queries avoid file
bodies in both variants; the experiment does not measure full file-read memory.

## Retained checkpoints and corrections

- `c922641` initially decoded recipients serially on the fan-out worker. Before
  timing this was replaced with independent subscriber decoder workers (`4591997`),
  preventing application construction from blocking shared native refresh. No
  performance claim is made for the serial implementation.
- The first small screen (12 rows) used new scopes but unchanged mixed-query
  results. It is retained as functional preflight, not mixed-query acceptance.
  The corrected sentinel screen at `d24d867` passes all 12 rows. Both binaries,
  fixture directories and logs remain outside Git; no record-size/budget was
  silently weakened to improve a ratio.
- Initial harness compilation rejected an async nil-coalescing autoclosure;
  the final branch uses explicit asynchronous branches. There was no timed run
  of that failed build.

## Full matrix

Five-sample medians, milliseconds. The two variants use the same native query
validation; sharing additionally retains independent application decoding and
per-consumer newest mailboxes. Equal consumers of one native execution share its
actual local view/diagnostics. There is no fabricated scope per delivery.

| Case | Observers | Shape | Independent wave ms | Shared wave ms | Independent/shared ratio |
|---|---:|---|---:|---:|---:|
| small | 1 | equal | 38.60 | 38.57 | 1.00 |
| small | 1 | mixed | 38.26 | 38.19 | 1.00 |
| small | 8 | equal | 148.40 | 38.24 | 3.88 |
| small | 8 | mixed | 152.33 | 150.74 | 1.01 |
| small | 32 | equal | 663.25 | 38.47 | 17.24 |
| small | 32 | mixed | 656.99 | 675.05 | 0.97 |
| flat-500 | 1 | equal | 181.54 | 177.67 | 1.02 |
| flat-500 | 1 | mixed | 183.23 | 178.34 | 1.03 |
| flat-500 | 8 | equal | 786.28 | 182.91 | 4.30 |
| flat-500 | 8 | mixed | 806.61 | 789.25 | 1.02 |
| flat-500 | 32 | equal | 3250.71 | 180.98 | 17.96 |
| flat-500 | 32 | mixed | 3228.56 | 3264.87 | 0.99 |
| flat-2000 | 1 | equal | 739.46 | 741.23 | 1.00 |
| flat-2000 | 1 | mixed | 729.71 | 742.40 | 0.98 |
| flat-2000 | 8 | equal | 3136.74 | 740.16 | 4.24 |
| flat-2000 | 8 | mixed | 3108.00 | 3116.03 | 1.00 |
| flat-2000 | 32 | equal | 12688.27 | 734.52 | 17.27 |
| flat-2000 | 32 | mixed | 12905.83 | 12980.64 | 0.99 |
| file-1 | 1 | equal | 47.43 | 45.83 | 1.03 |
| file-1 | 1 | mixed | 44.82 | 44.75 | 1.00 |
| file-1 | 8 | equal | 138.35 | 45.52 | 3.04 |
| file-1 | 8 | mixed | 170.74 | 172.17 | 0.99 |
| file-1 | 32 | equal | 697.09 | 46.01 | 15.15 |
| file-1 | 32 | mixed | 699.43 | 707.77 | 0.99 |
| file-10 | 1 | equal | 38.74 | 38.32 | 1.01 |
| file-10 | 1 | mixed | 38.89 | 38.87 | 1.00 |
| file-10 | 8 | equal | 168.68 | 39.01 | 4.32 |
| file-10 | 8 | mixed | 156.59 | 165.61 | 0.95 |
| file-10 | 32 | equal | 690.56 | 39.39 | 17.53 |
| file-10 | 32 | mixed | 677.45 | 676.52 | 1.00 |

Selected 32-equal-observer resource and startup medians:

| Case | Independent startup ms | Shared startup ms | Independent wave CPU ms | Shared wave CPU ms | Independent peak MiB | Shared peak MiB |
|---|---:|---:|---:|---:|---:|---:|
| small | 904.83 | 892.53 | 2607.80 | 40.77 | 33.75 | 18.75 |
| flat-500 | 4476.09 | 4409.22 | 12481.88 | 190.16 | 78.75 | 22.92 |
| flat-2000 | 17854.50 | 18096.18 | 48078.91 | 762.11 | 238.69 | 36.80 |
| file-1 | 912.49 | 912.49 | 2724.87 | 45.52 | 34.30 | 19.02 |
| file-10 | 907.16 | 913.93 | 2729.28 | 42.26 | 34.14 | 19.00 |

## Independent confirmation

Five-sample wave median (minimum–maximum), ms. Full startup/CPU/RSS/scopes remain
in each campaign summary and metrics JSONL.

| Case | Observers | Shape | Independent | Shared |
|---|---:|---|---:|---:|
| flat-500 | 1 | equal | 184.54 (182.01–188.46) | 187.24 (179.80–192.17) |
| flat-500 | 1 | mixed | 183.85 (180.47–187.12) | 184.31 (183.60–187.61) |
| flat-500 | 8 | equal | 774.73 (692.02–837.99) | 182.92 (182.15–196.54) |
| flat-500 | 8 | mixed | 775.03 (659.68–857.53) | 756.93 (755.23–836.43) |
| flat-500 | 32 | equal | 3277.27 (3190.00–3382.05) | 182.63 (180.07–187.33) |
| flat-500 | 32 | mixed | 3306.90 (3235.07–3639.15) | 3228.85 (3200.03–3314.40) |
| file-10 | 1 | equal | 38.78 (38.32–39.68) | 38.50 (37.81–38.65) |
| file-10 | 1 | mixed | 38.83 (37.94–39.06) | 38.47 (38.21–39.18) |
| file-10 | 8 | equal | 170.07 (153.87–179.66) | 38.62 (38.21–38.79) |
| file-10 | 8 | mixed | 162.51 (123.96–179.91) | 160.33 (146.62–168.75) |
| file-10 | 32 | equal | 699.13 (674.38–731.99) | 38.82 (38.76–39.92) |
| file-10 | 32 | mixed | 690.73 (663.92–732.72) | 676.54 (656.71–718.42) |

## Execution evidence and limits

`executionScopes` counts distinct delivered native read views, a lower bound on
independent native reads. Candidate counters also retain attempted native reads
between completed startup and delivery; they can include a subsequently cancelled
coalesced refresh. These are query executions, not native transactions/cloud
exports or durable progress. The actual distributions are:

| Campaign | Shape | Observers | Independent scopes min–max | Shared scopes min–max | Shared attempts min–max |
|---|---|---:|---:|---:|---:|
| full | equal | 1 | 1–1 | 1–1 | 2–2 |
| full | equal | 8 | 8–8 | 1–1 | 2–2 |
| full | equal | 32 | 32–32 | 1–1 | 2–2 |
| full | mixed | 1 | 1–1 | 1–1 | 2–2 |
| full | mixed | 8 | 8–8 | 8–8 | 16–16 |
| full | mixed | 32 | 32–32 | 32–32 | 64–64 |
| confirmation | equal | 1 | 1–1 | 1–1 | 2–2 |
| confirmation | equal | 8 | 8–8 | 1–1 | 2–2 |
| confirmation | equal | 32 | 32–32 | 1–1 | 2–2 |
| confirmation | mixed | 1 | 1–1 | 1–1 | 2–2 |
| confirmation | mixed | 8 | 8–8 | 8–8 | 16–16 |
| confirmation | mixed | 32 | 32–32 | 32–32 | 64–64 |

Selection remains limited to exact descriptors on one explicit coordinator/handle.
Mixed descriptors keep independent reads; there is no dependency suppression.
Joins and explicit refresh can cause additional updates for existing group members.
The initial subscription cost remains roughly proportional to subscriber count,
and heavy application decoders/startup churn need representative workload checks.
The candidate also adds a raw-input mailbox and a refresh worker per group; a
single observer or all-distinct workload must not be sold as a sharing gain.
The full matrix's largest mixed-wave median regression is about 5.8% (four
10-MiB files/eight mixed observers); its independent confirmation does not retain
that regression. The 500-node single-observer confirmation is about 1.5% slower
with overlapping ranges. These descriptive samples do not prove zero overhead.

Native source cancellation/account inspection are package boundaries. The default
public observation implementation is unchanged. Combine uses its existing cold,
demand-aware adapter over the laboratory factory; no native owner or lifetime
policy is delegated to a publisher operator. Cursor observations remain rejected.
Independent model construction, failures and cancellation preserve their consumer
scope; there is no shared decoded application instance or cross-operation cache.

The runs retain two attempted refreshes per group during a write wave (2/16/64
attempts for equal/8-mixed/32-mixed workloads), while delivering one current view
per group. Attempts can be cancelled before native admission; they are not a
claim of exactly one completed native call per update. No queued hint was
suppressed merely to improve the counter.

## Correctness and adoption gates

The final local suite passes 494 tests: 322 legacy, 88 store, 61 runtime and 23
model. Nineteen selected tests pass under Thread Sanitizer (nine laboratory,
five Combine, five invalidation). An additional decoder failure/recovery and
concrete-model isolation regression was added after timing, without changing
library/harness code or the retained binary. Manifest and diff checks pass.
Code checkpoint d24d867 passes macOS and iOS 18.5 Simulator CI (run 40569922396),
including all three laboratory smokes and the Swift 6 consumer. The final
test/documentation head is separately tracked in #83. Tests cover descriptor/budget/handle/model boundaries, shared read identity,
independent model construction, last-owner drop, cancel/join races, late in-flight
join, account supersession, relation/action/file invalidation, ordering, failure
recovery, native store hints and Combine demand/cancellation. Injected sources and
read checkpoints reproduce races deterministically; they are not real cross-user
CloudKit synchronization evidence. Default-query regression coverage remains.

Before changing public observe/publisher, settle shared view/cursor semantics,
model-decoder envelopes and duplicate refresh policy; exercise slow consumers,
representative decoders and size distributions. Revalidate native notification,
account/import/permissions and sibling-handle lifetimes on supported devices.
Keep broad invalidation until narrower dependency tracking separately demonstrates
correctness. Mandatory v1 migration and schema/beta gates remain open. This result
does not authorize a merge, automatic public activation or schema freeze.

## Provenance and external artifacts

Raw fixtures/logs stay outside Git; OS cleanup can remove temporary evidence.
This tracked report retains outcomes, conditions and decision boundaries.

- Initial functional screen: `/tmp/graphevo-c04-screen-20261027` (12 rows).
- Corrected screen: `/tmp/graphevo-c04-sentinel-screen-20261027` (12 rows).
- Full matrix: `/tmp/graphevo-c04-matrix-20261027` (300 timed rows).
- Confirmation: `/tmp/graphevo-c04-confirm-20261027` (120 timed rows).
- Immutable executable copies: `/tmp/graphevo-c04-binaries/`.

Binary SHA-256: `a531d2fcd6830a4f7b91984e2c1c4a9fc3932f4dae72d87899150793a9fd38d7`.
Runner SHA-256: `cc60756f3f451c681db1b42b65b7d522631414cecfd71ca474798a2b6fd2ee8e`.
