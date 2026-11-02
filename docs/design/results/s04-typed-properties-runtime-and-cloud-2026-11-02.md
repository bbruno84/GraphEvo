# S04 typed properties — runtime costs and CloudKit evidence

Date: 2026-11-02. Scope: P03 of the
[typed-property contract](../graphevo-2-typed-properties.md).

## Outcome

The selected S04 route works through real Graph CRUD/query/PH and independent
CloudKit owner/participant recovery. Fourteen physical stages pass with complete
application inventories, topology, values, assets and empty upload queues. Cloud
continues to store serialized primitives rather than local property columns.

The direction is retained. At 400 records, selected record queries and sorted
pages improve about 3x; open/full integrity/PH also improve. Simple count and
aggregate show small costs in that fixture. Disk grows about 7%, while measured
whole-process peak falls about 16%. These are complete runtime measurements,
not TP01's isolated predicate timings.

An explicit limit remains: at 2,000 records and the same 100,000-step allowance,
S04's native sort path refuses the request, while S03 succeeds. No result is
returned and the budget is not raised. This is retained as a pre-beta capacity/
work-accounting follow-up, not erased from the comparison or called acceptance
of every dataset. No additional model change is justified by this evidence.

## Source and protocol

P01 integrates through [#133](https://github.com/bbruno84/GraphEvo/pull/133).
P02 integrates through [#134](https://github.com/bbruno84/GraphEvo/pull/134).
Final reviewed shipping source is `0226a2d34cfe3df9a303d7b463dbcafc93b57147`,
validated by [CI #351](https://github.com/bbruno84/GraphEvo/actions/runs/41408938116).
All shipping source bytes in both external laboratories were compared to that
source; only external probe/benchmark entry points were added to disposable copies.

Initial physical seed/reciprocal edits used `cfaabc6`; subsequent empty recovery,
restart and explicit-null stages use the corrected source above. Source changes
between these revisions affect query header materialization and lazy aggregation,
not storage schema, CloudKit serialization, assets or sharing. Final physical
checks include native count, selected full records, lazy sum and full integrity.

The initial green CI #349 did not certify the final code: a benchmark semantic
assertion exposed missing lazy aggregate lookup. It was corrected and covered
before #351 and merge. Early benchmark setup also compared automatically dated
records to absent dates; that harness was corrected to explicit creation dates.
Those failed runs were retained locally and excluded from timing samples.

Laboratories, raw logs, device details, protected invitation transports, generated
stores and binaries remain local. The original GraphEvoDemo checkout was not
modified. Preparation uses a disposable signed demo export and package-only
production ContextManager/GraphStore operations, with no alternate persistence
or sync implementation. Device paths are relative app-data-container paths,
resolved on each transfer. No absolute container paths are persisted.

## Complete runtime measurement

Machine: Apple M2 Pro, 16 GiB, macOS 27.0.1, Xcode 27.2. Standalone Swift Release
consumer; one variant/fixture per process. Baseline uses the S03 schema and its
existing encoded-property query path; candidate uses S04 and P02, from the same
reviewed runtime. No cloud session is started in the desktop benchmark.

The principal matrix has three independent fresh fixtures per variant, alternating
variant order. Each fixture contains 400 application entities with eleven values:
Int64 score/group, String title, Bool, UInt64, Date, 4-KiB Data, Decimal, Object,
based URL and UUID. It also has one owned 2-MiB attachment. Both variants receive
identical values and semantic assertions, including exact returned records/order,
counts/sums, metadata, full integrity and PH/batch results.

Each repeatable operation runs five times per process; the table is the median
of each process's median. Seed, full integrity, initial PH collection, batch
preparation and reopen run once per fixture. Setup/open are separate from query
latency. The table includes all measured operations, not only improvements.

Identical explicit query allowances: 410 native candidates, 32 MiB weighted
property/structural bytes, 100,000 logical steps. No allowance is increased for
S04. Native candidate count includes hidden graph infrastructure. Byte/step
diagnostics are the contract's tariffs and logical work, not physical SQL I/O.

| Operation | S03 median ms | S04 median ms | S03 / S04 |
| --- | ---: | ---: | ---: |
| Seed 400 entities | 3373.84 | 3298.97 | 1.02 |
| Point full record | 2.86 | 2.80 | 1.02 |
| Single scalar count | 64.07 | 69.82 | 0.92 |
| Three-atom compound count | 81.59 | 75.75 | 1.08 |
| Two-field projection | 82.08 | 71.61 | 1.15 |
| Filtered full records, limit 5 | 223.36 | 71.04 | 3.14 |
| Ordered full records, limit 10 | 224.87 | 75.64 | 2.97 |
| Exact integer sum | 65.10 | 66.95 | 0.97 |
| Owned attachment metadata | 87.19 | 70.94 | 1.23 |
| Full local integrity | 224.52 | 147.04 | 1.53 |
| Initial PH collection | 192.09 | 118.26 | 1.62 |
| Prepare 100 pending records | 241.74 | 190.54 | 1.27 |
| Reopen/full admission | 232.65 | 156.65 | 1.49 |

Median complete fixture disk bytes: S03 **6,345,624**, S04 **6,785,816** (+6.9%).
This includes native store/support/history/checkpoint state after the same workflow,
not just SQL table payload. Median whole-process `getrusage` peak bytes: S03
**69,402,624**, S04 **58,359,808** (−15.9%). This cumulative process peak is not
per-query resident allocation or a production memory envelope.

The single-scalar count diagnostics report S03 memory evaluation, 25,112 charged
bytes and 801 steps; S04 native evaluation, 14,022 charged bytes, 7,628 steps and
9 native fetches. Native execution still pays graph inventory/header/ownership
costs. It must not be described as the isolated SQL predicate's latency.

### Larger allowance-boundary fixture

One additional fresh fixture/process per variant contains 2,000 entities and the
same attachment. The candidate allowance becomes 2,010 solely because the fixture
contains more rows; both variants still use 32 MiB and 100,000 steps. Five query
invocations per operation retain semantic assertions and record budget refusals.
This is a capacity investigation, not a three-fixture performance acceptance;
local device-host compilation overlapped part of setup, so its setup timings are
not used as comparative release evidence.

All operations except S04 sort pass their assertions. Selected full records take
approximately 1,154 ms S03 / 361 ms S04; simple count is approximately 357 / 355 ms.
All five S04 sort invocations refuse the step allowance without partial output;
S03's corresponding sort passes. The refused operation is retained as
`sortPage: steps`, never replaced by a larger allowance or an unbounded fallback.
The native preparation/merge and residual ordering account for more work than
the older evaluator. Review this before declaring the supported beta envelope.

## Physical CloudKit and sharing

Devices: iPad (10th generation), iPadOS 27.0, owner account; iPhone XR,
iOS 18.7.11, a different participant account. Test container:
`iCloud.com.valerioburiani.GraphCKDemo`, Development. Fresh GraphIDs, zones,
stores and stage reservations; **no container reset** and no copied native stores.

The owner has A (read-write share), B (unshared private control) and C (read-only
share). A contains a primary entity, child entity, relationship, action and owned
2-MiB asset; B and C each contain one application entity. Tests compare all
application IDs/records and endpoints, not only a visible count. Native roots and
membership infrastructure remain excluded. Independent server zone inventories
include the expected CKShare count; the guest cannot discover private B.

The value corpus covers Bool, Int64 minimum, UInt64 maximum, a subnormal Double,
negative zero, 38-digit Decimal, Unicode/NUL strings, NUL/Unicode keys, Data,
Date, UUID, ordinary/based URLs, Array, Object, encoded values and nested null.
A later consumer patch adds top-level null to A, testing both patch import and
fresh native-null insertion, native null equality and missing/null distinction.
Every reader also checks the attachment content/digest, full integrity and native
query results. Server primitive payloads are compared to expected non-attachment
records; actual attachment download verifies CKAsset materialization locally.

| Stage | Device / replica | Evidence |
| --- | --- | --- |
| 1 | XR / peer | Protected sharing identity, no store yet |
| 2 | iPad / owner | Seed A/B/C, publish, invite read-write A/read-only C |
| 3 | XR / peer | Accept and recover exact inventories/values/asset |
| 4 | XR / peer | Consumer edit A to 2 and publish |
| 5 | iPad / owner | Independently observe 2; controls unchanged |
| 6 | iPad / owner | Consumer edit A to 3 and publish |
| 7 | XR / peer | Independently observe 3; controls unchanged |
| 8 | XR / fresh | Empty shared replica, fresh engine state, recover 3 |
| 9 | XR / fresh | Process restart, retained replica and native query/sum |
| 10 | iPad / owner | Process restart, all private graphs and native query/sum |
| 11 | iPad / owner-empty | Empty private replicas recover A/B/C and asset |
| 12 | iPad / owner | Consumer patch A to 4 plus top-level null |
| 13 | XR / fresh | Import 4/null; native null equality; no feedback |
| 14 | XR / null-fresh | Another empty shared replica recovers 4/null and asset |

All fourteen stages pass. The last participant check specifically requires
`permissionDenied` for a write to C. Every completed verification observes empty
PH upload work and no retained outgoing receipt/error. Writers stay alive until
independent peer observation. Later process replacement occurs after that barrier;
no consumed mutation is replayed. Final demo processes are stopped only after
all independent observations finish. Test data remains; no remote wipe is used.

## Retained scope and next gates

This closes the bounded P03 local/physical route for S04 typed property adoption,
not a general sync certificate, global ordering, APNs/background delivery,
S03-to-S04 converter or production v1 cutover. Existing local S04 backup,
workspace/publication and v1-conversion tests remain separate from this physical
cloud protocol. Mandatory v1 migration, historical source acceptance and public
bootstrap/cloud activation remain open.

Before beta, review the measured disk/index tariff and the 2,000-row sort work
refusal, plus broader representative datasets/device capacity. Do not change the
schema again solely to make a microbenchmark attractive. The current evidence
supports continuing with S04's native/serialized routing and independent cloud
format while retaining the explicit limits above.
