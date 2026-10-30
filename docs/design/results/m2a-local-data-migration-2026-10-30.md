# M2a local data migration — validation (2026-10-30)

Outcome: the first package-only data/version execution slice passes **14 behavior
tests** and the **553-test** complete macOS package suite (331 legacy, 135 store,
64 runtime, 23 model). This builds on the aligned M1 foundation in PR #95; it is
not production/public migration admission. See [the contract](../graphevo-2-data-migration-local.md).

## Accepted local evidence

- Consumer data-format 1→2 conversion runs on actual disposable SQLite stores
  for Entity, Relationship and Action rows, including valid empty/absent endpoints.
  Values, native version and root effect marker commit together. Unknown nested
  values, UInt64.max, null, bytes and optional timestamps retain their meaning.
- A simulated interruption after native commit leaves a pending journal. Native
  close/reopen and a later run confirm the actual target/marker and finish the
  checkpoint without invoking either consumer conversion or publication again.
- An interruption before publication retains prepared data. Proven unchanged
  preimage plus absent marker yields explicit retry-required; the next call
  publishes the prepared result without rerunning the consumer.
- Concurrent edits before publication are rejected by a full selected-record
  compare-and-check. A matching marker with subsequently changed target data is
  unresolved, not a false successful migration. Pending evidence is retained.
- Undeclared, zero and future versions do not match declared version 1. The
  consumer is never called for those inputs. An explicit undeclared→zero route
  succeeds, proving that nil is not silently interpreted as zero.
- Throwing/structurally invalid transformations and budget failures do not publish
  partial data. Rejection of a later native write rolls back earlier pending
  record values and native versions; the operation remains reconcilable.
- Cancellation before native publication preserves the preimage; cancellation
  after a successful save still finishes trusted checkpoint work. Same-artifact
  concurrent admission is refused using a deterministic continuation gate.
- Corrupt/wrong-destination artifacts are preserved and refused. A complete closed
  source-directory copy reopens with the original values/version after conversion.
- Ordinary public S01 opening refuses the laboratory's model identifier after
  completion, preventing access through a facade without version-aware admission.

All data is synthetic and externally temporary. No application/device/cloud
store, native schema shape, production opening path or v1 manager is changed.

## Retained development corrections

Initial compilation required explicit returns after adapter guards and a fully
qualified model-kind type in the parameterized Swift Testing macro. These were
type-inference/test construction corrections, not relaxed migration assertions.

Initial preservation checks found the test seed was asking ordinary insertion
to create a record with no supplied date; that API generates a timestamp. The
laboratory archived-source seeder now explicitly represents an absent native
date. Whole-row preservation assertions remain unchanged, and ordinary public
insertion behavior is untouched. The final suite includes absent-date preservation.

Raw build/selected/full logs remain outside Git under `/tmp/graphevo-m2a-*`.
Manifest, changed-document links and diff checks pass. No generated native stores,
prepared payload artifacts, journal files or raw logs are committed.

## Limits

The first external CI passed iOS but exposed an unrelated in-memory observation
failure on macOS. The [coherence follow-up](in-memory-read-coherence-2026-10-30.md)
records the original failure, a deterministic mixed-view regression and the
runtime correction. The original 553-test local result above remains historical;
the corrected complete suite adds two runtime behavior tests.

Failures are injected around native publication followed by actual store reopen;
there is no process-kill/power-loss or cross-process acceptance claim. The local
adapter's source/effect proof does not apply to NSPersistentCloudKitContainer
imports. The laboratory model identifier deliberately excludes normal public
read/write/query access; journal completion does not relabel/activate the store.

Public model-format contracts, compatibility floors, every normal admission path,
source protection/retention ownership and dependency/route scheduling remain M2b.
Late/partial/unknown cloud formats remain M6; full GraphEvo v1 data conversion and
the optional compatibility layer remain M3–M5. Source API compatibility is optional,
while mandatory v1 data migration is unchanged. No beta/release gate is implied.
