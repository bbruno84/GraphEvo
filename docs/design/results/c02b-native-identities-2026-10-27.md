# C02b native identity lookup — local evidence, 2026-10-27

Status: local experiment measured; native columns are the next integration candidate, subject to the gates below.

## Boundary and decision

This is a package-only alternative-model experiment after `c4b6745`. The default
model/public openers, integration branch and alpha tag are unchanged. No CloudKit
schema or device store is modified. Read the [contract](../graphevo-2-native-identity-experiment.md)
and [runner](../../../Experiments/IdentityLookup/README.md).

## Method

Release arm64 executable, macOS 27.0.1, fresh process per operation; five samples
per operation/case/variant. Process startup and store opening are excluded from
operation latency and recorded separately. OS caches are uncontrolled; these are
not cold-storage measurements. `residentAtEnd` is final RSS, not a sampled peak;
no peak-memory improvement is claimed. No local builds/tests run during timing.

The three variants use matched independent local fixtures: the public full
inventory adapter; optional native graph/node String columns without a configured
index; the same columns with a compound fetch index. All use normal runtime
leases, queues, read pins, writer serialization and commit guards. The prototype
checks the requested node/references; the public adapter inventories unrelated nodes and validates their
routing/format metadata. It does not decode every unrelated application payload. Their timings do **not** describe equivalent production
contracts or a drop-in API speedup.

Six cases: 100, 500 and 2000 entities; four graphs with 125 entities each; 100
entities plus one 10-MiB attachment; and 500 entities with an action referencing
all 500 as both subjects and objects. Every graph also has an edge and an action.
Each entity has five properties (including explicit null and an unknown encoded
value), tag/group and a stable date. File bytes repeat a deterministic 256-byte
pattern; this identity probe is not representative media storage evidence.

Each campaign creates an owned current-alpha source, closes it, copies its whole
directory twice, converts each copy to a new store with inferred mapping, then
validates/backfills/activates. Sample fingerprints preserve kinds, IDs, endpoints,
properties, dates, tags/groups and exact owned attachment content. Original source
SQLite hashes must stay unchanged. This does not prove full v1/local/cloud
migration. Conversion timings include backfill and validation, with one sample
per variant/case, and are not statistically stable estimates.

## Retained failures and first checkpoint

The first store-specific migration attempt failed on a disposable source with
Cocoa 134110 / SQLite 8 (`attempt to write a readonly database`). The explicit
copy-to-new-store probe uses the generic mapping manager instead. The failure
remains in `/tmp/graphevo-c02b-tests.log`; no production auto-migration is enabled.

Checkpoint `548807344d66335ff19ca893c3b240d52381ed6e` completed 528 rows. Its
native resolver issued three requests per endpoint: fast Entity results hid a
serious wide-action regression. These outcomes remain part of the evidence.

| Operation | Public full inventory, ms | Native columns, ms | Configured index, ms |
|---|---:|---:|---:|
| flat-500 read | 47.39 | 2.95 | 2.99 |
| flat-500 patch | 48.42 | 3.92 | 3.77 |
| flat-2000 read | 184.05 | 2.92 | 2.70 |
| flat-2000 patch | 192.16 | 4.18 | 3.87 |
| fanout read-action | 54.00 | 675.21 | 648.17 |

The revised checkpoint batches up to 128 distinct endpoint UUIDs, checking all
three node kinds per batch. It retains raw/native identity, membership, backing
object and duplicate checks. A 130-endpoint regression crosses the boundary and
rejects pending cross-kind duplicates and missing endpoint columns.

## Intermediate batching result and corrected local-view check

The UUID-batching-only campaign at `4d162f4` completed another 528 rows:
wide-action read was 51.27 ms full, 280.34 ms columns and 277.02 ms indexed.
Batching requests alone was insufficient; this variant is not selected.

The next candidate prefetches native topology (not property bodies) and batches
only graph/node/staging metadata for referenced owners. Changed owners use the
facade's pending local view. A regression initially exposed a newly inserted
staging property that the batched-property path missed; the fallback and tests
now retain that pending guard. The failing run is retained externally as
`/tmp/graphevo-c02b-topology-regression.log`.

A one-repetition wide-action screen at `c5e0ce7` passed (20 rows), with indexed
read at 33.74 ms. This screen only authorizes the complete repeated campaign;
it is not the final performance conclusion.

## Final repeated campaign

Source: `a5586a2ac567e64c2b40fe62871429629e6f583c` (endpoint implementation
`c5e0ce7`, followed by an entry-point filename fix for Xcode 16). Full matrix:
528 rows; independent confirmation on new fixtures: 264 rows. Five samples per
operation/variant in both, including full validation after patching. All
conversions and checks succeeded; no failed conversion/stage was replayed.

The final candidate batches endpoint identities and selected identity/staging
metadata, prefetches topology without property bodies, and uses facade reads for
changed owners. It retains reference membership and backing-object checks.

Medians in milliseconds; full means public inventory adapter, columns means no
configured compound index. The independent validation scopes described above
remain different.

| Case | Operation | Full | Columns | Indexed |
|---|---|---:|---:|---:|
| small | read | 11.30 | 2.77 | 2.80 |
| small | read-edge | 10.95 | 3.84 | 3.69 |
| small | read-action | 11.05 | 3.62 | 3.54 |
| small | missing | 10.90 | 1.06 | 1.03 |
| small | patch | 12.16 | 3.90 | 4.15 |
| flat-500 | read | 46.26 | 2.72 | 2.79 |
| flat-500 | read-edge | 46.35 | 3.58 | 3.73 |
| flat-500 | read-action | 45.95 | 3.47 | 3.67 |
| flat-500 | missing | 45.81 | 1.10 | 1.04 |
| flat-500 | patch | 46.78 | 4.03 | 3.86 |
| flat-2000 | read | 184.20 | 3.38 | 3.17 |
| flat-2000 | read-edge | 186.76 | 4.18 | 3.62 |
| flat-2000 | read-action | 187.41 | 3.94 | 3.63 |
| flat-2000 | missing | 182.86 | 1.26 | 1.05 |
| flat-2000 | patch | 198.38 | 4.17 | 4.13 |
| four-graphs | read | 21.86 | 2.91 | 2.85 |
| four-graphs | read-edge | 21.27 | 3.74 | 3.76 |
| four-graphs | read-action | 21.14 | 3.94 | 4.06 |
| four-graphs | missing | 21.70 | 1.09 | 1.08 |
| four-graphs | patch | 22.36 | 4.04 | 3.87 |
| file | read | 11.60 | 2.50 | 2.68 |
| file | read-edge | 11.04 | 3.40 | 3.81 |
| file | read-action | 11.08 | 3.31 | 3.58 |
| file | missing | 10.94 | 1.03 | 1.10 |
| file | patch | 12.43 | 11.78 | 11.70 |
| fanout | read | 46.39 | 2.83 | 2.75 |
| fanout | read-edge | 46.67 | 3.88 | 3.67 |
| fanout | read-action | 47.86 | 31.01 | 30.88 |
| fanout | missing | 46.09 | 1.10 | 1.06 |
| fanout | patch | 47.55 | 4.21 | 3.91 |

Independent confirmation, median (minimum–maximum), ms:

| Case / operation | Full | Columns | Indexed |
|---|---:|---:|---:|
| flat-500 / read | 47.57 (47.17–48.47) | 2.65 (2.61–2.73) | 2.59 (2.56–2.86) |
| flat-500 / patch | 50.01 (46.84–51.74) | 4.04 (3.87–4.44) | 3.92 (3.74–4.11) |
| flat-2000 / read | 190.07 (174.35–197.77) | 2.89 (2.60–3.01) | 2.80 (2.71–2.87) |
| flat-2000 / patch | 188.50 (185.24–219.23) | 4.45 (4.42–4.59) | 3.96 (3.69–4.17) |
| fanout / read-action | 48.85 (47.08–53.34) | 31.19 (30.73–31.51) | 31.25 (30.36–31.65) |

Explicit whole-graph validation is intentionally separate and stronger than a
single public record read: it snapshots/validates every application record,
including file checks. It is not a cloud-import completeness certificate.

| Case | Columns validation, ms | Indexed validation, ms | Columns conversion, ms | Indexed conversion, ms |
|---|---:|---:|---:|---:|
| small | 38.38 | 38.38 | 199.63 | 206.11 |
| flat-500 | 175.73 | 175.79 | 828.38 | 845.08 |
| flat-2000 | 728.94 | 711.77 | 3718.19 | 3491.02 |
| four-graphs | 55.54 | 54.92 | 1038.48 | 1056.42 |
| file | 57.43 | 57.31 | 353.27 | 355.85 |
| fanout | 178.33 | 181.47 | 900.99 | 878.29 |

## Interpretation and next gates

- Keep native graph/node columns as the candidate for selective point access.
  The large gain is avoiding the application-node inventory. A configured index
  gives a much smaller difference on these sizes; these runs do not establish a
  universal index benefit or a particular native SQL plan.
- Do not generalize the scalar-only patch gain to file-bearing graphs: that
  case stays about 12 ms (12.43 full versus 11.70 indexed), despite its cheaper
  scalar read. Explicit 2000-node validation remains about 0.71–0.73 s; it has
  not become a cheap per-operation substitute.
- Retain the bounded endpoint strategy. The first two resolvers regressed on
  a high-degree action; the final repeated campaigns remove that regression on
  the measured fixture without removing identity/membership checks.
- Do not run whole-graph validation after every point operation. Define where
  durable migration/import and explicit integrity checks establish sufficient
  state for target checks. Missing columns can still look absent; production
  absence, incomplete imports, raw/native disagreement and returning old writers
  are unresolved contracts, not optimizations to bypass.
- Keep C02 open for integrated native assignment/sharing, private/shared store
  conversion and recovery, snapshot/import semantics and mandatory v1 migration.
  No default model change, schema freeze, beta entry or production migration is
  authorized by this local result. C04 observer work remains the next independent
  cost investigation; it must preserve source/lifecycle/cancellation semantics.

## Validation and retained artifacts

Final local suite: 483 tests (322 legacy, 78 store, 60 runtime, 23 model) pass.
Ten selected tests pass under Thread Sanitizer (six identity, four invalidation).
The local aggregate Xcode scheme runs the six identity tests successfully.
The additional executable requires `GraphEvo-Package` for Xcode package tests;
CI also exposed `@main` in `main.swift` on Xcode 16, fixed by naming the source
`IdentityLookupProbe.swift`. These build failures are retained, not test failures
hidden by disabling checks. Package manifest and diff checks pass before
publishing the final report. CI status is recorded in the PR.

The first new wide-action assertion compared against an unspecified date and
failed; the fixture now fixes that date and compares the complete record.
The pending-staging regression described above then caught a real prototype
local-view error before timing the final candidate.

Raw metrics, fixture stores, binaries and logs stay outside Git. The final and
confirmation directories include environment revision/dirty state, binary/runner
hashes, every invocation log, metrics JSONL and full median/min–max tables:

| Campaign | External directory | Rows |
|---|---|---:|
| Initial N+1 resolver | `/tmp/graphevo-c02b-initial-20261027` | 528 |
| UUID batching only | `/tmp/graphevo-c02b-batched-20261027` | 528 |
| Topology screen | `/tmp/graphevo-c02b-topology-screen-20261027` | 20 |
| Final full campaign | `/tmp/graphevo-c02b-final-20261027` | 528 |
| Independent confirmation | `/tmp/graphevo-c02b-confirm-20261027` | 264 |

Temporary artifacts are local evidence and may be removed by OS cleanup; this
tracked report preserves decisions and results. Executables remain under
`/tmp/graphevo-c02b-binaries/`; no application stores or device data were used.

Final binary SHA-256: `dd72d2c7734d21a7ab11c40e53ae6bff54957fbde3393bc8c0d2bc2f6e551545`.
Runner SHA-256: `6b728281d16d224350b5633ed7a548e04543e373e9e9bf9f4ce7b9b9b8aa8f00`.
