# C01 — integrated local cost baseline

Date: 2026-10-27. Status: screening evidence and proposed priorities, not a
supported production envelope. Read the [consolidation plan](../graphevo-2-consolidation.md)
and [reproducible consumer](../../../Experiments/ConsolidationCosts/README.md).

## Environment and reproducibility

The measured library is the A8 integration commit
`caa12129cd535c2ffd8bfbbf7e302a223d04815a`, unchanged by this experiment.
The independent Swift 6 harness was built in Release with Xcode 27.1 / Swift 6.4
on macOS 27.0.1 (26A434), Mac14,10 with 16 GiB RAM. Harness/docs were working
source, not yet committed. There is no claim of an immutable published harness.

The first matrix retained 163 validated samples on seven fixtures: seven seed
samples plus 156 operation samples. A later matched two-graph/no-file control
added 19 samples after the regression suite completed, totaling **182 across
eight configurations**. Each non-seed operation has three independent process
runs. A separate one-repetition small-case smoke validated the runner; its nine
points are excluded from the table. Runner metadata was extended after the
first matrix to capture harness hashes; the later control records those hashes.
The Swift measurement executable stayed unchanged during these trials.

Every fixture was a new external temporary directory with a local SQLite store.
No real app data, CloudKit setup/record/zone, account, device fixture, model or
library API was changed. No failed seed was replayed and no unexpected outcome
occurred. Nine default-budget refusals were expected and explicitly asserted.
Raw metrics, logs and stores remain outside Git; this report contains reviewed
aggregates. No conclusions depend on private Core Data/CloudKit metadata.

The selected query matches one Entity by integer property and does not request
file content. Nodes each have three encoded scalars, one tag and one group.
File bytes are deterministic varied synthetic data, not real photos/documents.
Cases small/flat-500 have one graph and 100/500 nodes. Five-graphs has five graphs
of 100 nodes; two-graphs is the matched 2 × 100 no-file control. Files-here has
100 nodes and four 1-MiB files in the selected graph; files-elsewhere places those
files in the second graph. Large-file cases use one/four 10-MiB files with 100
selected-graph scalar nodes. Files retain the accepted exclusive owner identity.

## Time and memory

Operation latency below excludes open/selected-handle attachment, which had
medians around 11–15 ms. Fresh processes prevent reuse of prior native contexts,
but OS/SQLite caches and host load remain uncontrolled. These are medians and
ranges of three samples, not confidence intervals, P95 values or device limits.

Memory is the median whole-process sampled peak: native setup, open, operation,
framework/cache contributions and close are included. Sampling at nominal 10-ms intervals plus
explicit endpoints may miss short peaks; OS high-water was also retained in raw
metrics. This does not measure exact copied/allocated application bytes.

| Fixture | Operation | Median ms | Min–max ms | Sampled process peak MiB | Result |
|---|---|---:|---:|---:|---|
| small | fetch | 90.03 | 89.23–137.67 | 16.6 | pass |
| flat-500 | fetch | 431.49 | 424.40–454.04 | 17.8 | pass |
| small | query | 141.34 | 135.89–163.08 | 17.1 | pass |
| flat-500 | query | 617.94 | 603.78–627.96 | 18.8 | pass |
| five-graphs | query | 173.15 | 172.21–176.40 | 18.2 | pass |
| two-graphs | query | 135.43 | 134.65–141.70 | 17.2 | pass |
| files-here | query | 158.11 | 154.20–169.38 | 31.6 | pass |
| files-elsewhere | query | 138.48 | 138.03–144.52 | 25.4 | pass |
| one-large-file | query | 193.41 | 190.64–198.99 | 83.0 | pass |
| four-large-files | query | 327.49 | 324.42–335.30 | 110.1 | budgetExceeded(propertyBytes) |
| four-large-files | query-raised | 424.40 | 402.10–427.98 | 123.7 | pass |
| small | list | 181.52 | 179.15–188.07 | 17.0 | pass |
| one-large-file | list | 259.15 | 257.98–263.17 | 83.0 | pass |
| four-large-files | list | 594.92 | 565.72–613.12 | 137.4 | pass |
| one-large-file | read | 265.58 | 255.26–268.36 | 110.2 | pass |
| small | patch | 87.45 | 86.13–87.65 | 16.7 | pass |
| flat-500 | patch | 402.38 | 398.62–415.27 | 18.0 | pass |
| small | observe1 | 356.81 | 352.02–369.69 | 17.6 | pass |
| small | observe8 | 1688.19 | 1579.64–1746.20 | 21.4 | pass |
| flat-500 | observe1 | 1681.40 | 1644.26–1710.84 | 19.6 | pass |
| flat-500 | observe8 | 8203.81 | 8161.96–8215.56 | 30.0 | pass |
| files-here | observe8 | 1870.97 | 1853.78–1875.72 | 102.6 | pass |

An observer cycle includes all initial reads, an existing-property patch and all
observers recovering that unique new revision. Eight observers execute eight
initial and at least eight refresh queries; the table is whole-cycle latency,
not per-event/UI frame latency. Coalescing/duplicate native hints can produce
additional work. No Combine-versus-async performance comparison is claimed.

## Work and storage counters

| Query fixture | Native candidates | Scoped records | Charged property bytes | Rows returned |
|---|---:|---:|---:|---:|
| small | 102 | 100 | 24,890 | 1 |
| flat-500 | 502 | 500 | 124,890 | 1 |
| five-graphs | 510 | 100 | 24,890 | 1 |
| two-graphs | 204 | 100 | 24,890 | 1 |
| files-here | 106 | 104 | 5,708,414 | 1 |
| files-elsewhere | 208 | 100 | 24,890 | 1 |
| one-large-file | 103 | 101 | 14,225,497 | 1 |
| four-large-files, raised allowance | 106 | 104 | 56,827,350 | 1 |

Query, count and projection all snapshot scoped properties before evaluating
this filter; they therefore have comparable work even when returning one scalar
row/count. Four 10-MiB files exceed the default 32-MiB property allowance before
the unrelated scalar query can complete. Raising it to 128 MiB permits that same
query at a sampled process peak around 124 MiB; it does not remove the coupling.
The refusal is the documented budget contract, not a new correctness failure.

Other-graph files do not enter the selected graph's charged property bytes, but
native candidates still include that graph. The matched two-graph control
separates adding another graph from adding files to it; small timing differences
across these separate runs do not establish a reliable speed ranking. This is
not proof of graph-selective SQL I/O or zero physical file materialization.

After the original read-only operations and close, apparent directory bytes were
about 0.60 MiB for small, 5.95 MiB for files-here, 13.99 MiB for one-large-file
and 54.72 MiB for four-large-files. These include SQLite/auxiliary/fixture files,
not allocated filesystem blocks or a claim of physical external placement.
The implementation stores a binary attachment envelope inside the JSON-coded
GraphValue Data representation; base64 wrapping plus metadata is consistent with
the observed charged-payload/storage amplification. These totals do not isolate
serialization overhead from every native/auxiliary contribution.

Seed has one sample per fixture: 100 nodes took 185 ms, 500 nodes 2,191 ms and
five successive 100-node graphs 12,069 ms. Those totals include graph creation,
save and close (plus file import in other fixtures), so they are not insertion
latency distributions. Their shape identifies the repeated inventory/validation
path as a candidate for targeted profiling, not proof of one exclusive cause.

## Conclusions and next implementation direction

1. **Decouple binary content from scalar/metadata reads.** The current one-value
   file envelope makes an unrelated query fail its allowance and makes metadata
   listing decode/hash complete file content. Keep GraphNodeID, exclusive owner
   and graph/share scope while prototyping separate metadata/body and avoiding
   JSON/base64 for binary bytes. Native assignment, partial recovery, exact reads,
   backup and migration must follow the changed representation.
2. **Make identity/catalog/session access selective.** Fetching one scalar node
   rose from about 90 to 431 ms and patching from 87 to 402 ms between 100 and
   500 selected-graph nodes, while open remained around 12–13 ms. The adapter
   currently rebuilds Session inventory/membership even for these operations.
   This code path plus observed scaling motivates C02; attribution still needs
   targeted profiling/A-B candidates. Do not remove invariant checks to improve
   a timing result without a validated replacement route.
3. **Share observer work after fixing input costs.** Four 1-MiB files increased
   the eight-observer cycle's sampled process peak from about 21 to 103 MiB.
   The current engine independently snapshots each query. Preserve A8's related
   invalidation/error/cancellation guarantees while comparing shared selective
   snapshots and narrower dependency invalidation. Parallelism alone leaves
   repeated reads and can amplify memory pressure.
4. **Do not freeze the current representation or publish limits from C01.** These
   findings support C02/C03/C04 prioritization, not a selected final native schema,
   stable file-size promise or completed M12 review. Repeat on realistic data and
   physical devices after candidate improvements, then revisit supported budgets.

The accepted file identity/ownership logic remains intact. Source migration is
mandatory: a new representation must retain original bytes and old-to-new
references and have actual native sharing evidence. This experiment neither
changes schema nor closes account/conflict/recovery, durable processing,
platform/process, migration-feasibility or beta-entry gates.

## Verification

The independent Release consumer completed the matrix and final runner smoke,
checking result shape/identity, exact attachment metadata/content validation,
expected budget refusals and each observer's refreshed marker. Root manifest,
diff/link checks and all **464 regression tests** pass. macOS CI now builds and
runs only a small functional harness smoke; timings are not CI pass thresholds.
The new workflow still requires its first CI run. No new hardware, CloudKit or
sanitizer claim follows from this local cost screen.
