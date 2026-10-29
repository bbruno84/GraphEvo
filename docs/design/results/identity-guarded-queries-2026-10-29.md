# Identity-guarded query materialization — local result (2026-10-29)

Status: focused public-path alpha implementation PR #85, stacked on #84.
The current native schema, store-opening path and complete structural inventory
remain. This is selective body materialization, not adoption of C02b native
identity columns or indexed SQL query execution.

## Correctness and validation

- Full local suite: 501 pass (322 legacy, 95 store, 61 runtime, 23 model).
- Selected Thread Sanitizer: 44 pass (39 query/materialization/cancellation/public
  observation/laboratory/Combine, five native invalidation), no reported race.
- Manifest, diff, Python AST and Release probe build pass.
- Same-model excluded 1-MiB bodies no longer exhaust a small ID-query allowance;
  selected complete bodies still charge/fail, and all eligible model fields/null
  values, cursor pages, count/projection/aggregation and native candidate counts
  remain checked. A foreign graph still contributes to candidate allowance.
- Property-before-ID errors, unbounded OR/NOT and related dependencies retain
  conservative evaluation. Pending insert/patch/delete and complete edge/action
  endpoint sets are covered. Excluded corrupt ID/format metadata still fails.
- The native transformer probe now has an excluded poison body on the SAME model
  type: ID query/projection performs zero poison transformations, while requesting
  that ID still fails. Supported-SDK CI is a separate acceptance step.
- A new action test first expected one subject although the existing fixture has
  two. Its expected endpoint set was corrected; production behavior was unchanged.
  The failed intermediate regression log is retained, followed by the passing
  full/sanitizer runs. No production invariant was relaxed to bypass a failure.

Local logs: `/tmp/graphevo-id-query-{selected,regression,full,tsan,release}.log`.
The parent #84 exact-head CI passed macOS/iOS (run `40828821638`); that is distinct
from the new PR's own CI, which must be checked before merge.

## Matched Release comparison

The retained pre-change binary creates one new closed 500-node scalar seed.
Every implementation/variant/repetition receives a complete copy of that same
seed directory. No application/device/cloud store is touched. The new comparison
option records implementation labels and both binary hashes. Baseline precedes
candidate within each matched repetition; OS caches are uncontrolled, not cold
storage evidence. No local build/test ran during timing. No failed stage was
replayed and no fixture/query budget or correctness assertion was weakened.

Three fresh-process repetitions cover 1/8/32 equal/mixed descriptors and both the
public shared path and retained independent A8 control: 72 rows. Every initial
and updated result preserves expected IDs, unchanged revisions and the common
changed sentinel. Update waves include the write and all deliveries; startup is
separate. RSS is sampled for the whole process, not a query allocation bound.
Distinct delivered scope IDs are not a count of all native attempts.

| Implementation | Case | Observers | Mode | Variant | Samples | Startup median ms | Wave median ms | Wave CPU median ms | Peak median MiB | Scopes min–max |
|---|---|---:|---|---|---:|---:|---:|---:|---:|---:|
| baseline | flat-500 | 1 | equal | independent | 3 | 146.24 | 186.08 | 194.63 | 21.23 | 1–1 |
| candidate | flat-500 | 1 | equal | independent | 3 | 83.73 | 125.05 | 129.47 | 20.91 | 1–1 |
| baseline | flat-500 | 1 | equal | shared | 3 | 145.61 | 186.82 | 195.42 | 21.30 | 1–1 |
| candidate | flat-500 | 1 | equal | shared | 3 | 83.70 | 124.25 | 128.89 | 21.09 | 1–1 |
| baseline | flat-500 | 1 | mixed | independent | 3 | 145.79 | 185.05 | 193.44 | 21.08 | 1–1 |
| candidate | flat-500 | 1 | mixed | independent | 3 | 82.04 | 122.41 | 126.78 | 20.88 | 1–1 |
| baseline | flat-500 | 1 | mixed | shared | 3 | 145.07 | 185.84 | 194.17 | 21.22 | 1–1 |
| candidate | flat-500 | 1 | mixed | shared | 3 | 81.17 | 123.40 | 128.05 | 20.89 | 1–1 |
| baseline | flat-500 | 8 | equal | independent | 3 | 1135.85 | 822.45 | 2907.75 | 38.09 | 8–8 |
| candidate | flat-500 | 8 | equal | independent | 3 | 648.71 | 463.37 | 1538.40 | 35.75 | 8–8 |
| baseline | flat-500 | 8 | equal | shared | 3 | 1136.36 | 184.13 | 192.92 | 21.92 | 1–1 |
| candidate | flat-500 | 8 | equal | shared | 3 | 651.06 | 124.41 | 129.30 | 21.47 | 1–1 |
| baseline | flat-500 | 8 | mixed | independent | 3 | 1132.90 | 832.67 | 3104.50 | 37.61 | 8–8 |
| candidate | flat-500 | 8 | mixed | independent | 3 | 665.28 | 451.90 | 1475.05 | 36.66 | 8–8 |
| baseline | flat-500 | 8 | mixed | shared | 3 | 1150.40 | 811.51 | 2913.97 | 38.42 | 8–8 |
| candidate | flat-500 | 8 | mixed | shared | 3 | 636.13 | 531.77 | 1903.15 | 35.62 | 8–8 |
| baseline | flat-500 | 32 | equal | independent | 3 | 4692.59 | 3388.12 | 13044.92 | 76.22 | 32–32 |
| candidate | flat-500 | 32 | equal | independent | 3 | 2555.34 | 2490.56 | 9874.54 | 68.52 | 32–32 |
| baseline | flat-500 | 32 | equal | shared | 3 | 4737.00 | 189.30 | 198.86 | 23.23 | 1–1 |
| candidate | flat-500 | 32 | equal | shared | 3 | 2552.13 | 126.15 | 132.09 | 22.14 | 1–1 |
| baseline | flat-500 | 32 | mixed | independent | 3 | 4610.80 | 3378.28 | 12851.63 | 76.45 | 32–32 |
| candidate | flat-500 | 32 | mixed | independent | 3 | 2625.41 | 2522.23 | 9920.70 | 69.36 | 32–32 |
| baseline | flat-500 | 32 | mixed | shared | 3 | 4579.51 | 3403.34 | 13342.11 | 76.67 | 32–32 |
| candidate | flat-500 | 32 | mixed | shared | 3 | 2554.63 | 2495.62 | 9792.18 | 70.25 | 32–32 |

## Public-path wave ranges

| Observers | Shape | Baseline min–max ms | Candidate min–max ms |
|---:|---|---:|---:|
| 1 | equal | 185.42–193.07 | 122.91–128.85 |
| 1 | mixed | 185.01–190.47 | 119.69–132.29 |
| 8 | equal | 183.23–190.68 | 124.40–129.88 |
| 8 | mixed | 806.25–855.58 | 515.05–562.78 |
| 32 | equal | 187.04–194.29 | 124.99–128.71 |
| 32 | mixed | 3366.54–3491.48 | 2463.33–2528.77 |

The public-path medians improve across this bounded comparison. Eight equal
observers update in 184 to 124 ms; 32 equal update in 189 to 126 ms. Their startup
falls from 1136 to 651 ms and 4737 to 2552 ms respectively. Eight mixed descriptors
fall from 812 to 532 ms, 32 from 3403 to 2496 ms. One equal observer falls from
187 to 124 ms. The retained independent path also improves, distinguishing the
body-materialization gain from C04's native-read sharing.

Sampled public-path RSS changes only modestly: 32 equal 23.23 to 22.14 MiB,
32 mixed 76.67 to 70.25 MiB. Do not describe this as another large memory gain.
No median timing regression appears in these samples, but three repetitions of
one scalar fixture do not define a production envelope, tail latency, physical
CloudKit behavior or a universal absence of regressions.

## Scope, provenance and follow-up

- Candidate clean source: `e7c23da54804419657bf54837c7344d5c5df01b4`.
- Candidate binary SHA-256: `29617ca2470c5c68dbf74f23914976dc02ed483636f4bc0ec0c7ee11f4680b5a`.
- Retained baseline source: `a69b1b6b9eae2e1db757a5568320646d496da581`.
- Baseline binary SHA-256: `e483d904e4a0469a7ff7faccb86c5bae335f02233c3cab62622f1db72fa0ab66`.
- Comparison runner SHA-256: `80d9553109d258ee6afec8a6fa0ba8b740f632ce3dcda100e1cd153967c0979e`.
- Host: `macOS-27.0.1-arm64-arm-64bit-Mach-O`.
- Candidate binary: `/tmp/graphevo-c04-binaries/identity-guard-e7c23da-ObservationCostProbe`.
- Baseline binary: `/tmp/graphevo-c04-binaries/public-a69b1b6-ObservationCostProbe`.
- Complete external artifacts: `/tmp/graphevo-id-query-compare-20261029`, including
  metrics, environment, summary, per-stage logs and complete modified copies.
  No raw stores/logs enter Git.

The [query contract](../graphevo-2-queries.md#c02-consolidation-identity-guarded-materialization)
retains all native candidate/identity/membership/endpoint/format-list checks and
evaluation steps. Only property bodies proven unreachable before property access
are skipped; they are not certified or charged. Complete eligible records retain
all fields. No limit-driven early slicing, smaller candidate inventory, query
fallback, cross-scope cache, native schema change or automatic migration is used.

Startup still scales with subscription count. Different descriptors still scan
independently and 32 mixed queries still take about 2.5 seconds on this fixture.
Retain those costs. C02b native columns, missing/partial-column absence semantics,
old writers, native private/shared import/conversion, heavy/slow application models
and mandatory coordinated v1 migration remain separate integration gates. This
result does not freeze the schema, promote the integration line or authorize beta.
