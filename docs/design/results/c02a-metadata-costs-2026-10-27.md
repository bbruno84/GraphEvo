# C02a — reserved metadata batching comparison

Date: 2026-10-27. Status: positive local experiment; **B is the preferred
experimental candidate**, not integrated into the v2 branch or a schema choice.
Read the [experiment contract](../graphevo-2-metadata-experiment.md),
[C01 baseline](c01-cost-baseline-2026-10-27.md) and
[consolidation plan](../graphevo-2-consolidation.md).

## What changed

The previous adapter repeatedly walked per-node property relationships to read
reserved identity, graph membership, format and staging metadata. Variant A
fetches those property rows in bounded owner batches into a Session-local
lookup, keeping values lazy. It retains complete native-node inventory and all
validation; it is not a selective native UUID index or application-data cache.
Variant A is preserved in commit `61154a5` on the experiment branch.

A substantially improved reads but made the 500-node seed much slower. Variant
B batches persisted owners only, groups by native kind and persistent store,
sets affectedStores explicitly, and uses the original lookup for temporary/new
owners or inventories with at most two persisted nodes. Pending property edits
on persisted owners remain included. No index crosses a Session/context boundary.
The native model/hashes, layout revisions, IDs, public API, file representation,
query allowances and integrity/ownership checks are unchanged.

## Method and provenance

The library baseline is C01 commit
`e2177e04952eca2150450598008d7cbe88711a5c`, with A8 integrated. A copied
self-contained baseline Release executable and independent A/B executables were
retained externally with SHA-256 files; they link system frameworks rather than
a working-tree GraphEvo dynamic library. Editing/rebuilding the candidate cannot
change the copied baseline's implementation.

Each of baseline/A/B ran the unchanged C01 eight-case matrix in its own new
external directory: 182 validated samples each (546 total). Every non-seed
operation has three fresh-process runs; seed has one. A later baseline repeat
of small/flat-500 added 50 points, totaling **596**. All outcomes were asserted,
including nine expected default property-budget refusals per full matrix.
No failed benchmark mutation was replayed. Raw stores/metrics/logs/binaries
remain outside Git; this report retains reviewed aggregates.

The first baseline started while the initial experimental build/local test was
finishing. The later small/flat-500 repeat ran without another build/test job;
the table uses that repeat for those two cases and the original baseline for
remaining cases. Its results retain the same large improvement pattern. This
is descriptive screening, not randomized-order statistical inference. A/B and
the repeats did not overlap other benchmark/build/test jobs. Host caches/load,
UUIDs and tiny encoded-metadata size differences remain uncontrolled.

Mac14,10 / 16 GiB, macOS 27.0.1, Xcode 27.1 / Swift 6.4, Release, public API
consumer and synthetic data match C01. Source was working/uncommitted during
trials; A/B are not claimed to be immutable published build snapshots. Later
B edits were tests/docs/formatting rather than further executable logic changes.
Operation latency excludes open; observer cycles include all initial reads,
the existing-property patch and every observer recovering the unique new marker.

## Timing

All figures are medians of three processes except seed's single descriptive
sample. Baseline/B is a ratio of these observations, not a release guarantee.

| Case | Operation | Baseline ms | A ms | B ms | Baseline/B |
|---|---|---:|---:|---:|---:|
| small | seed | 216.92 | 262.08 | 172.54 | 1.26× |
| flat-500 | seed | 2341.15 | 11722.95 | 2204.65 | 1.06× |
| five-graphs | seed | 12441.29 | 8186.87 | 7720.26 | 1.61× |
| small | fetch | 89.91 | 8.39 | 9.15 | 9.82× |
| flat-500 | fetch | 463.50 | 36.89 | 34.76 | 13.34× |
| flat-500 | query | 676.04 | 131.23 | 132.00 | 5.12× |
| flat-500 | count | 661.50 | 129.78 | 131.84 | 5.02× |
| flat-500 | project | 655.30 | 132.17 | 130.15 | 5.04× |
| flat-500 | patch | 397.92 | 35.29 | 35.41 | 11.24× |
| flat-500 | observe8 | 8784.09 | 1699.99 | 1685.45 | 5.21× |
| files-here | observe8 | 1892.41 | 515.22 | 520.27 | 3.64× |
| one-large-file | fetch | 104.26 | 9.42 | 8.56 | 12.18× |
| one-large-file | read | 266.02 | 68.20 | 68.05 | 3.91× |
| four-large-files | query-raised | 404.81 | 213.11 | 215.98 | 1.87× |

B preserves the large read/patch gain while avoiding A's 11.7-second 500-node
seed. The small-seed result varies between baseline runs (177 and 217 ms), so
its apparent B improvement is not a reliable insertion-latency claim. The
five-graph seed improves in this screen but still takes seconds: full inventory
is still repeated, so C02 is not complete.

## Memory and unresolved costs

| Case / operation | Baseline peak MiB | B peak MiB |
|---|---:|---:|
| flat-500 / observe8 | 30.2 | 38.2 |
| files-here / observe8 | 97.7 | 105.7 |
| one-large-file / fetch | 70.7 | 16.8 |
| four-large-files / query-raised | 123.8 | 124.7 |

These are sampled **whole-process** peaks, including frameworks/open/close,
not exact query allocations or hard maxima. Samples are nominally 10 ms apart.
The eight-observer peak grows in the candidate: more prefetched metadata and
concurrent snapshots remain alive. Thus B is not an across-the-board memory
improvement. One-node fetch in a file-bearing graph avoids materializing the
large application property while reading reserved metadata, giving a substantial
peak reduction in that case.

Application queries still snapshot attachment content. Four 10-MiB files still
exhaust the default 32-MiB property allowance for a scalar query/count/projection;
raising it still costs about 125 MiB process peak. Metadata-only file listing
still decodes/hashes contents, and each observer still reruns its own query.
C03 content separation and C04 shared observation work remain necessary.

Native candidate/scoped-record counts and result assertions are unchanged.
Full selected-graph metadata/membership/endpoint checks still run; no test or
query limit was relaxed to obtain the speedup. C02's wider goal of avoiding
full inventory for a single lookup remains open.

## Correctness and native-resource checks

The final B source passes **469 macOS tests** (322 legacy, 60 runtime, 66 store,
21 model) and **19 targeted Thread Sanitizer tests** without a reported race.
The independent Swift 6 ModelConsumer passes. New regressions cover:

- Pending inserts across the 128-owner boundary on SQLite and in-memory stores,
  all node kinds, later pending format/property edits on persisted owners,
  endpoint deletion and control-graph isolation.
- Duplicate/missing/cross-graph identity rejection, malformed other-graph format
  isolation and successful fresh reads after repair.
- Two separate SQLite resources on one coordinator with distinct metadata and
  complete native membership validation.
- A unique test-only secure transformer that records/fails a foreign metadata
  decode: the selected graph does not touch that value and the foreign graph
  visibly exercises it. This validates lazy access; it does not change the
  production transformer or model.

The B executable also opens and queries an existing baseline-created fixture
successfully, without application writes or migration. This checks format reuse,
not immutable SQLite sidecars or mandatory v1 migration completeness.

### Physical read-only check

A configured disposable demo used the B working source on the authorized iPad
(owner, iPadOS 27.0) and XR (different account, iOS 18.7.10), preserving the source
demo/signing configuration. Ticket `BA420C46-57D0-420C-9ED1-3A5B3AF6139F` read
the retained successful A6 private/shared pair after A8's deletion. No ticket,
mutation, invitation or native recovery stage was replayed.

Both devices agreed on the retained A8 parent's typed query, count and ID fetch.
The iPad retained the original B attachment's complete metadata/exact 512 bytes;
B was absent from the XR catalog. Both reports passed. There were no requested
application mutations, share/permission/account changes or cloud resets. Native
opening may still perform framework bookkeeping/imports. This is actual paired
resource access, not fresh recovery, new shared insertions, partial assignment,
real account-change or cross-device mutation evidence. Those remain required
before claiming complete sharing acceptance for the candidate.

### Retained development failures

The first decoder-isolation test used a plain ValueTransformer, which is not
the Core Data secure-transformer family required by Apple, and failed its fixture
read. It was corrected to NSSecureUnarchiveFromDataTransformer; the targeted and
full tests then passed. This was a test-fixture defect, not a discarded library
regression. An exploratory swift -e command also crashed the host interpreter
frontend; it was not a library/device crash and supplied no measurement evidence.
No generated crash logs, store contents or native account/identity values are
committed. Relevant Apple contracts are linked from the experiment document.

## Decision for this experiment

Retain B on the experiment branch and keep A in history for comparison. Do not
merge or freeze a new schema from these results alone. Next work should compare
metadata/content separation and shared selective inputs while preserving this
metadata gain, migration/backup requirements and all graph/share boundaries.
The candidate has no observed failure in the stated regression/read scenarios;
it has explicit memory trade-offs and incomplete native-write coverage.
