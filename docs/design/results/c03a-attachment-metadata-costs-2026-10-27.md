# C03a result — split attachment metadata

Date: 2026-10-27. Decision: retain this isolated local candidate for further
validation; do not integrate or declare native sharing/representation acceptance.
Read the [experiment contract](../graphevo-2-attachment-metadata-experiment.md),
[A6 contract](../graphevo-2-attachments.md) and
[consolidation gates](../graphevo-2-consolidation.md).

## Candidate and comparison

Baseline is preferred C02a B, `e2e53ab5743b117e74ffc52ea9d9ab133b8818bb`.
Candidate implementation is `352d30a`, on
`codex/v2-attachment-metadata-experiment`, a child of B. No integration branch
or alpha.8 tag changed. Native model/hashes, public signatures, identity,
exclusive owner and graph membership remain unchanged. The new logical file
format requires a compatible reader; this is not a schema/API freeze.

New files use a small version-2 `attachmentMetadata` envelope plus original
bytes in `content`, on the same Entity. Both still use GraphValueCodec with
JSON/Base64 wrapping. Listing explicitly decodes only metadata. Existing A6
files remain readable/listable/exportable/deletable; replacement preserves their
old envelope instead of silently converting or adding new shared detail rows.
Full reads and sharing integrity checks still validate the body checksum.
Split metadata listing is descriptive and does not attest body availability.

Both immutable standalone Release executables ran the unchanged eight-case C01
matrix, three fresh processes per non-seed operation: 182 samples each. A second
run of flat-500, files-here, one-large-file and four-large-files added 100 samples
per executable. Total: **564 validated measurements**, including 36 expected
property-budget refusals. No fixture was replayed after failure. There were no
unexpected measurement failures. No build/test job ran during either matrix.

## Listing outcome

Times are median milliseconds. Each cell is first run / independent confirmation,
with three samples per run. Peak RSS is the median whole-process sampled peak,
not incremental allocations or a hard maximum.

| Listing case | B ms | Split ms | B peak MiB | Split peak MiB |
|---|---:|---:|---:|---:|
| Four 1-MiB files | 39.16 / 36.91 | 17.38 / 17.62 | 31.2 / 31.2 | 23.8 / 23.7 |
| One 10-MiB file | 68.87 / 67.97 | 23.60 / 15.61 | 83.4 / 83.4 | 71.2 / 17.0 |
| Four 10-MiB files | 218.58 / 219.23 | 30.24 / 28.74 | 134.1 / 134.1 | 71.3 / 71.4 |

The four-large-file listing is approximately 7.2–7.6 times faster with a lower
sampled process peak. The one-large-file memory variation is retained, not
replaced with the better sample. Avoiding explicit body codec/hash work does
**not** demonstrate body-size-independent native faulting, I/O or memory.
No external-content placement or private framework behavior is inferred.

## Controls, remaining costs and trade-offs

| Operation | B ms, first / confirmation | Split ms, first / confirmation |
|---|---:|---:|
| 500-node scalar query | 132.96 / 133.77 | 131.21 / 132.01 |
| 500-node eight-observer cycle | 1600.27 / 1719.02 | 1723.79 / 1700.25 |
| Four 1-MiB files: scalar query | 46.47 / 46.40 | 52.82 / 46.58 |
| Four 1-MiB files: eight-observer cycle | 507.40 / 512.95 | 514.50 / 508.04 |
| One 10-MiB file: complete read | 68.82 / 67.50 | 67.61 / 68.17 |
| Four 10-MiB files: read one | 69.63 / 68.83 | 68.16 / 67.78 |
| Four 10-MiB files: query with 128-MiB allowance | 211.86 / 212.11 | 212.79 / 212.62 |

Initial scalar-query/eight-observer fluctuations did not reproduce as a stable
regression in the confirmation. These small samples cannot prove absence of
regressions in other workloads. Seeds are single observations per fixture:
500-node B 2218 / 2282 ms, candidate 2276 / 2316 ms, not an insertion distribution.

Query/count/projection with four 10-MiB files still refuse the **unchanged**
32-MiB default allowance, with no partial result. The raised-budget query still
charges approximately 56.83 MB (56,827,366 bytes in the candidate first run) and
peaks near 124.2 MiB. Query evaluation deliberately still snapshots file bodies;
splitting values alone does not remove this cost. C04 observer work is unchanged;
four-small-file observer sampled peaks remain around 102–107 MiB.

Apparent seeded directory sizes stay essentially unchanged: four-large-file
baseline 57,378,964 bytes versus split 57,370,772, and one-large-file 14,664,596
versus 14,672,788. These include native/application fixture artifacts; they do
not establish physical allocation savings. There is one additional native
property row per new file. JSON/Base64 and complete-read buffering remain.

## Correctness and limits

The final macOS suite passes **473 tests**: 322 legacy, 60 runtime, 69 store,
22 model. New coverage verifies split metadata/body mismatch, missing content,
future/malformed metadata, mixed old/new SQLite reopen, replacement retaining
old format and unknown properties/tags, owner cascade, and durable shared-intent
round-trip of both values. An injected invalid body codec is skipped by metadata
listing while complete reads and sharing integrity fail visibly. Existing
cancellation, maximum-size, rollback, export and backup/reopen tests also pass.
Root manifest, independent Swift 6 Release consumer build and diff checks pass.
The initial implementation required compiler fixes before these final checks;
no failed candidate was accepted or measured.

This experiment has **no new physical-device mirroring evidence**. The native
model and assignment mechanism are reused, but two-value participant insertion,
replacement, partial import/conflicting values and recovery still require
owner/participant device checks before adoption. A local transaction and a
round-trippable intent are not proof of atomic cloud import. Existing files are
preserved, not migrated to the new format. Coordinated alpha conversion and
mandatory v1 migration remain open; older A6 readers cannot consume split files.

## Reproduction and retained evidence

Use the unchanged [C01 runner](../../../Experiments/ConsolidationCosts/README.md)
with B and candidate standalone Release binaries, then repeat with
`--cases flat-500,files-here,one-large-file,four-large-files`. Source and harness
hashes, per-point metrics, logs, summaries and disposable stores remain outside
Git in `/tmp/graphevo-c03a-{baseline-b,split,baseline-confirm,split-confirm}-20261027`.
The runner records the current checkout revision, not a historical executable's
source revision: the baseline binary's provenance is B as stated above.

Executable SHA-256:

- B: `206d1f1832167e41832cfce2df589ab51ccb8e8807b7fb206649d227ce97b21e`
- Split: `07f2404304e4cdf6206558b017d7822bc0d2e4f258315fa8ab50fe9e690f6531`

Final full-test log: `/tmp/graphevo-c03-verified-tests.log`. Earlier failed build
logs and successful intermediate test logs are retained separately. Synthetic
bytes, uncontrolled OS/SQLite caches and host load, sampled RSS, and three-point
medians limit conclusions. Retain B independently and compare the next query
experiment separately; do not combine this local result with sharing acceptance.
