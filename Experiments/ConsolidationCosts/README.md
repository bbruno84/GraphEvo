# C01 — local persistence, file, query and observation costs

This independent Swift 6 consumer screens the integrated A1–A8 implementation
through public GraphDatabase/GraphStore APIs. It never opens a user-provided
store, enables CloudKit, inspects private native metadata or changes the library's
schema/API. Fixtures are newly seeded local SQLite directories outside Git.

## Run

```sh
swift build -c release --package-path Experiments/ConsolidationCosts
python3 Experiments/ConsolidationCosts/run.py \
  --executable /absolute/path/from-show-bin-path/CostProbe \
  --output /tmp/graphevo-c01-new-run
```

Find the executable directory with
`swift build -c release --package-path Experiments/ConsolidationCosts --show-bin-path`.
The output directory must not exist and must be outside the repository.
The runner refuses unknown cases/nonpositive repetitions and never retries a
failed seed/operation. Retain failed outputs and inspect them before designing
another trial. `--cases small,files-here` limits the matrix;
`--repetitions 3` is the default. This macOS harness is not a device or CloudKit
benchmark and does not define product acceptance thresholds.

Each fixture has 100 or 500 Entity nodes per graph. Each node has three encoded
scalar properties (integer index, 64-character name, revision), a tag and a group.
The selected query matches exactly one row, projects one key where requested,
and deliberately does not reference attachment content. File owners are pinned
application nodes, with four 1-MiB files, one 10-MiB file or four 10-MiB files.
File bytes use deterministic varied pseudorandom content, not a repeated small
block; they are still synthetic and not representative user media.

Eight cases compare one graph/100 nodes, one graph/500 nodes, five graphs/100
nodes, a matched two-graph control, selected-graph files, other-graph files, one large file and default-budget
exhaustion. A seed process writes the fixture and closes its native owner.
Every subsequent measurement executes in a fresh process and opens the same
fixture. SQLite/OS file caches remain uncontrolled: call this a fresh-process
reopen, not cold-storage I/O. Single patch/observer trials change an existing
revision field; they do not grow application node/property counts.

## Measurements and assertions

The runner checks one matching result/count/projection, pinned fetch identity,
expected file-owner counts and exact attachment metadata/content validation.
Only the four-large-files query/count/projection may return the expected default
32-MiB property-budget error. A separately labeled query raises that allowance to
128 MiB. An unexpected result/error stops the run. Native candidate allowance is
20,000; other query defaults remain unchanged.

The observation cycle includes N initial reads, one existing-property patch,
and N independent observers recovering the unique new revision. Every initial
result and refreshed marker is checked. The result reports N completions and
one observer's diagnostics, not aggregate work or unique transaction counts.
This measures the whole cycle; it is not steady-state UI frame latency,
minimal invalidation cost, slow-consumer pressure or a Combine comparison.

Metrics distinguish database open plus selected-handle attachment from the timed
operation. Open uses the actual catalog/membership path and is not covered by
A7 query allowances. Seed timing includes creation and all file imports, so its
single sample is descriptive rather than an insertion benchmark distribution.

A detached task samples whole-process resident memory at nominal 10-ms intervals; explicit
start/end samples are included. Record sample count, post-open resident bytes,
whole-process sampled peak and OS process high-water. Neither peak is attributable
only to application bytes or an exact allocation/copy count. Short peaks can be
missed; framework/setup/caches contribute. Directory bytes sum apparent regular
file sizes after close, including native auxiliary artifacts and small fixture
JSON files; they are not allocated disk blocks or proof of external placement.

The runner retains environment/revision/dirty-state metadata, validated JSONL
metrics, raw logs and summary Markdown externally. Source fixtures, binaries,
logs and stores must not be committed. Commit only reviewed aggregate findings
and their scope in docs/design/results, keeping current schema alternatives
separate from implemented release guarantees.

## Consolidation use

Use this first screen to prioritize measurable bottlenecks before selecting a
new schema: scalar/metadata reads versus binary content, graph-scoped candidate
lookup, repeated session/catalog validation, and repeated work per observer.
A candidate improvement must rerun the same matrix without changing visible
query/value/identity/ownership semantics, then validate on supported devices,
realistic data and native mirroring. It must preserve mandatory v1 migration,
backup completeness and graph/share boundaries. No schema is frozen by C01.
