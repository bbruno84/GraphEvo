# M2a — local data versioning and migration execution

Status: package-only vertical slice following the aligned M1 journal. Read with
[the manager roadmap](graphevo-2-migration-manager.md) and
[S01](graphevo-2-persistent-schema.md). This implements a local data effect and
checkpoint recovery, not production migration admission or consumer-facing APIs.
No native attribute/entity/index or default public opener changes.

## Scope and isolation

`GraphDataMigrationDefinition` declares a stable migration ID, algorithm revision,
logical kind/type, explicit graph-scoped record IDs, source format and target
format. A nil source is an explicitly declared undeclared format, distinct from
zero. Nonnegative declared versions must advance. Unknown/mixed source formats
are refused before invoking any consumer transformation; no decoder-success
heuristic or property-row `appDataVersion` fallback is used.

The synchronous Sendable consumer closure receives detached GraphRecord values
and returns updated properties/tags/groups. It must be pure: no external writes,
context retention or asynchronous work. Identity, type, endpoints and creation
date remain unchanged. Native schema plans, library-owned attachment evolution,
structural edits, global migration routing and durable cloud discovery are outside
this increment. Application-specific reconciliation policy remains consumer-owned.

Normal public GraphModel/GraphRecord/read/write/query APIs remain unchanged.
Versioned data is opened only through `GraphDataMigrationLaboratory`, a local
runtime owner using the exact S01 entity shape with a **laboratory model identifier**
`GraphEvo.dataMigration.lab.1`. Public S01 opening rejects that identifier, even
after migration completes. This prevents an unaware normal facade from interpreting
versioned data before M2b implements complete format admission. No existing S01
or v1 file is silently converted, relabeled or activated.

The adapter refuses a native cloud container, requires one local resource and
checks its laboratory model. Its destination identity binds canonical URL,
persisted store UUID and logical graph ID. It uses the ordinary runtime owner,
writer gate and scoped Node-facade adapter, with primitive native version metadata
access confined to that context. There is no app/widget or distributed fence.

## Prepare, publish and complete

1. Snapshot the explicit selection and validate every kind/type/source version
   before running the consumer. Compute a full selected-record source fingerprint.
2. Transform detached records and validate permitted structure/encoding before
   data edits. Native write constraints still apply inside publication; a later
   rejection rolls back earlier records' pending values and versions.
   Persist a private, versioned immutable prepared artifact with destination/
   definition binding, source/target fingerprints and the prepared target values.
   Existing artifacts are decoded/validated, never silently overwritten or recreated.
3. M1 persists an operation/step intent before publication. Inside one native
   transaction, re-read the complete selected source and reject stale analysis.
   Apply explicit property/tag/group changes, set `ge2DataVersion` and write the
   reserved root effect marker in that **same SQLite transaction**. The adapter
   does not save independently; runtime cancellation/rollback rules remain intact.
4. Reconcile the actual destination marker and full target fingerprint before
   confirming the journal. Record semantic validation and then journal completion.
   This is operation completion, not public-store activation or cloud replication.

The prepared archive uses the existing canonical GraphValue codec, preserving
null, UUID, unsigned boundaries, opaque values and nested values. It is a private
artifact format, not a public Codable contract for GraphRecord. At most 128
explicit IDs are admitted. The caller declares an encoded-byte allowance for
the input fingerprint and prepared artifact (default 1 MiB). Loading a large
existing artifact checks file size first. These are not total memory, native
I/O, callback runtime or graph-size bounds.

Artifact directories must be owned private laboratory paths. New directories
request permissions 0700 and new prepared files 0600. The archive contains values;
never log or commit it. The journal remains local and payload-free. Source
backup/protection is still an explicit host responsibility: whole closed directory
copies include native external content/sidecars; manager-owned production backup
and retention policy remain M2b work.

## Interruption and cancellation

On resume, the consumer closure is not called again for an existing valid
prepared artifact. A pending intent is classified by the trusted local adapter:

- Exact persisted intent and current target fingerprint: confirm the committed
  effect and finish the journal, without publishing again.
- No marker **and the full selected preimage still matches**, under the isolated
  local ownership assumptions: clear only that pending attempt and return
  `retryRequired`. A subsequent explicit call may publish the frozen prepared
  result with a new intent; it does not rerun arbitrary consumer code.
- Any other state, including a marker with changed target data: preserve pending
  intent and report reconciliation required. Missing evidence alone is not no effect.

Caller cancellation before native publication leaves the source unchanged and
the intent available for reconciliation. After a successful save, a separate
uncancelled task finishes trusted reads/checkpoint work and returns completion;
it runs no consumer transformation. Storage/validation failures still propagate.
No cross-file atomicity, fsync/power-loss guarantee or exactly-once external side
effect claim follows from Foundation atomic file replacement.

The manager admits one active operation per canonical artifact directory in its
process. Native source compare-and-check still rejects overlapping stale local
publications with different journals. Broader dependency scheduling is not implemented.

## Validation and next increment

The [local result](results/m2a-local-data-migration-2026-10-30.md) records 14 new
behavior tests and the complete 553-test package run with their actual limits.

Behavior tests cover all three native node kinds, actual data/version/marker
commit, post-commit interruption with native close/reopen, completed-operation
re-entry, explicit retry without callback replay, stale source and changed target,
undeclared/zero/future formats, transformation failure/structural refusal,
budgets/corrupt artifacts/destination binding, cancellation before/after save,
late native rejection with whole-batch rollback, same-artifact concurrent
admission and protected closed-source recovery.
The absent-date fixture is seeded explicitly: ordinary insertion with no supplied
date generates a timestamp and is not itself a historical missing-date fixture.

The tests model interruption by throwing at publication boundaries and reopening
the native store; they are not actual process-kill, power-loss or CloudKit tests.
M2b must settle public format declarations and admission across every read, write,
query, traversal, attachment and observation path before exposing versioned
records. Add real resource/process readiness, backup/retention and routing policy.
M6 must handle later old-format/partial/unknown cloud imports without assuming
a native pause. Mandatory v1 conversion and the evaluated compatibility layer
remain M3–M5 work; existing v1 migration APIs are untouched.
