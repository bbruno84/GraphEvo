# C04 public observation adoption — local verification (2026-10-29)

Status: focused implementation PR #84 after the reviewed C04a experiment (#83)
merged into the experiment parent at `9232993`. Public observe/publisher now use
one per-handle coordinator. This verifies the wiring; the historical
[C04a matrix](c04a-shared-observation-2026-10-27.md) remains the selection evidence.
No new native schema, physical CloudKit test, migration or integration/tag
promotion is claimed.

## Regression and ownership checks

- `swift test`: 497 pass (322 legacy, 91 store, 61 runtime, 23 model).
- Selected Thread Sanitizer: 28 pass (eight public observation, nine laboratory,
  six Combine, five invalidation), no reported race.
- Manifest, Python AST syntax, diff checks and Release probe build pass.
- New tests exercise eight concurrent first subscribers, per-handle/descriptor
  grouping, sibling survival after close, idle handle release and shared public
  async/Combine use with independent positive demand and cancellation.
- Existing deterministic laboratory tests exercise the same extracted coordinator,
  including fresh joins, model independence/failure recovery, source cleanup,
  native hints and injected account/cancel/join races.

Logs are retained outside Git under `/tmp/graphevo-c04-public-{full,tsan,release}.log`.
Exact-head remote CI is separate; check the current PR before review/promotion.

## Release public-path check

`shared` now runs actual `GraphStore.observe`; `independent` runs the retained
package-only A8 implementation. Both use the default native model/adapter, same
query budgets, complete closed seed copies and new disposable fixture directories.
Every received result must preserve expected IDs/revisions and contain the changed
sentinel. Reads with different descriptors remain independent. Startup is timed
separately; RSS is sampled over the whole process, not an intrinsic query heap cap.
No local builds/tests ran during measurement and no failed stage was replayed.

The first 16 rows use 500-node scalar and 100-node/four-10-MiB-file fixtures,
1/8 observers, equal/mixed shapes, one process per variant. This is a targeted
functional smoke, not a replacement statistical campaign or product threshold.

| Case | Observers | Mode | Variant | Samples | Startup median ms | Wave median ms | Wave CPU median ms | Peak median MiB | Scopes min–max |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|
| flat-500 | 1 | equal | independent | 1 | 452.01 | 233.40 | 241.44 | 21.58 | 1–1 |
| flat-500 | 1 | equal | shared | 1 | 172.39 | 212.28 | 218.32 | 21.72 | 1–1 |
| flat-500 | 1 | mixed | independent | 1 | 154.99 | 202.29 | 211.06 | 21.52 | 1–1 |
| flat-500 | 1 | mixed | shared | 1 | 148.86 | 202.29 | 210.35 | 21.91 | 1–1 |
| flat-500 | 8 | equal | independent | 1 | 1263.59 | 853.72 | 3325.50 | 37.47 | 8–8 |
| flat-500 | 8 | equal | shared | 1 | 1141.47 | 190.78 | 199.21 | 22.06 | 1–1 |
| flat-500 | 8 | mixed | independent | 1 | 1219.97 | 1055.75 | 3367.36 | 37.41 | 8–8 |
| flat-500 | 8 | mixed | shared | 1 | 1219.38 | 848.57 | 3133.92 | 37.67 | 8–8 |
| file-10 | 1 | equal | independent | 1 | 60.74 | 61.88 | 65.77 | 18.61 | 1–1 |
| file-10 | 1 | equal | shared | 1 | 35.18 | 43.40 | 45.71 | 18.38 | 1–1 |
| file-10 | 1 | mixed | independent | 1 | 34.47 | 41.49 | 43.49 | 18.45 | 1–1 |
| file-10 | 1 | mixed | shared | 1 | 31.43 | 41.79 | 43.59 | 18.31 | 1–1 |
| file-10 | 8 | equal | independent | 1 | 239.59 | 164.29 | 664.05 | 23.45 | 8–8 |
| file-10 | 8 | equal | shared | 1 | 245.43 | 42.12 | 44.54 | 18.55 | 1–1 |
| file-10 | 8 | mixed | independent | 1 | 243.32 | 191.34 | 713.59 | 23.59 | 8–8 |
| file-10 | 8 | mixed | shared | 1 | 253.10 | 233.42 | 686.42 | 24.16 | 8–8 |

The file-bearing eight-mixed smoke was slower (191.34 to 233.42 ms), so a separate
20-row comparison used fresh seeds/copies and five matched repetitions for eight
mixed observers on both fixtures. The unfavorable smoke row is retained; there
was no body/budget/fixture reduction or replacement of the earlier result.

| Case | Observers | Mode | Variant | Samples | Startup median ms | Wave median ms | Wave CPU median ms | Peak median MiB | Scopes min–max |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|
| flat-500 | 8 | mixed | independent | 5 | 1164.11 | 815.26 | 2958.30 | 38.06 | 8–8 |
| flat-500 | 8 | mixed | shared | 5 | 1156.57 | 787.03 | 2808.09 | 38.39 | 8–8 |
| file-10 | 8 | mixed | independent | 5 | 237.18 | 185.84 | 684.04 | 23.59 | 8–8 |
| file-10 | 8 | mixed | shared | 5 | 240.55 | 178.64 | 656.70 | 23.80 | 8–8 |

| Confirmation case | Variant | Wave min–max ms |
|---|---|---:|
| flat-500 | independent | 755.97–885.68 |
| flat-500 | shared | 638.36–806.35 |
| file-10 | independent | 165.13–195.45 |
| file-10 | shared | 164.92–180.91 |

The mixed slowdown was not retained in those five repetitions. Shared/independent
mixed results remain near their controls with overlapping ranges; do not infer
an improvement, zero overhead or a universal absence of regressions from these
small samples. Eight equal observers deliver one shared view instead of eight;
the 500-node smoke wave is 853.72 to 190.78 ms and file-bearing smoke is 164.29 to
42.12 ms. These are single samples. Queued/cancelled native attempts remain
reported separately from delivered views.

## Provenance and remaining gates

- Source checkpoint: `a69b1b6b9eae2e1db757a5568320646d496da581` (clean during both runs).
- Release binary SHA-256: `e483d904e4a0469a7ff7faccb86c5bae335f02233c3cab62622f1db72fa0ab66`.
- Runner SHA-256: `cc60756f3f451c681db1b42b65b7d522631414cecfd71ca474798a2b6fd2ee8e`.
- Host: `macOS-27.0.1-arm64-arm-64bit-Mach-O`.
- Complete local artifacts: `/tmp/graphevo-c04-public-smoke-20261029` (16 rows),
  `/tmp/graphevo-c04-public-mixed-confirm-20261029` (20 rows), including environment,
  metrics, summaries, modified clones and per-stage logs; no store/log enters Git.
- Binary copy: `/tmp/graphevo-c04-binaries/public-a69b1b6-ObservationCostProbe`.

The [adoption contract](../graphevo-2-observation.md#c04-consolidation-adoption)
settles shared view/refresh/join behavior. Initial subscription and different-query
costs remain. Heavy/slow application decoders, actual native import/account/access
coverage and representative physical-device envelopes still gate consolidation
promotion. Selective identity/query integration and mandatory coordinated v1 data
migration remain separate work. No cache, narrower invalidation or larger query
allowance was used to obtain this result.
