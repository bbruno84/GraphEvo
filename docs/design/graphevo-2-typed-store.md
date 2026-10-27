# GraphEvo 2 — persistent identity and typed local operations

Status: A3 local implementation, 2026-10-26. This extends the
[first model increment](graphevo-2-application-models.md) and completes its local
public CRUD path. The native Core Data model is still the existing candidate.
Cloud topology, replica recovery and cloud migration remain A4/A5 work.

## Public application flow

Import the existing GraphEvo product. `GraphStore` is a Swift 6 actor implemented
in GraphEvoStore, which depends on the Swift 6 runtime and detached model module.
The legacy Graph target supplies a package-only adapter using Node facades.
Application code needs no Core Data imports, native contexts or dynamic members.

```swift
let store = try await GraphStore.open(at: sqliteURL)
let profile = Profile(id: store.makeNodeID(), displayName: "Ada")
try await store.insert(profile)
let saved = try await store.fetch(profile.id, as: Profile.self)
let updated = try await store.patch(
    GraphRecordPatch(id: profile.id,
                     properties: ["display_name": .set("Grace".graphValue)]),
    as: Profile.self)
try await store.delete(profile.id)
try await store.close()
```

Profile is the ordinary application model in the [model guide](graphevo-2-application-models.md).
`open(at:)` requires an explicit local SQLite file, not a directory or CloudKit
configuration. `inMemory()` creates an independent graph. Existing incompatible
models are not migrated automatically. Opening a populated v1 store requires
explicit local adoption; an empty store gets a new logical graph ID.

`store.id` and `makeNodeID()` are nonisolated value APIs. A previously read model
can cross to a main-actor UI state or non-UI task. Changing that value does not
write a store. Reopening the same file retains graph/node IDs. Moving the closed
store with its sidecars retains those identities too; copying a store preserves
its logical identity rather than inventing another graph.

A3 currently maps one local logical graph to one physical resource. This does
not select a one-store-per-cloud-graph architecture. A4 can change membership
storage while preserving graph-aware public IDs and explicit format versions.

## Scopes and transaction semantics

`read` and `transaction` are awaited, with synchronous throwing Sendable bodies
and Sendable results. `GraphReadScope` offers record/typed reads; GraphMutation
adds insert, patch and delete. Scopes are not Sendable and expose no context.
The library invalidates them when their body returns. No nested async operation,
independent save or external side effect belongs inside a mutation body.

```swift
try await store.transaction { mutation in
    try mutation.insert(author)
    try mutation.insert(note)
    try mutation.insert(link)
}
```

Insert entities before creating references to them in the same transaction.
Entity UUIDs may be allocated beforehand, so cyclic graphs can be built with
edges after their entities. Reads within the mutation see earlier pending edits.
References must resolve to entities in this graph. Missing nodes, unresolved
references, graph mismatches, duplicate identities, corrupt metadata, reserved
names and model decoding errors are visible failures.

Each insert/patch validates and encodes its edits and resolves endpoints before
the first change. Typed patch decoding also happens before applying the patch,
so catching an invalid typed patch inside a larger body cannot accidentally
commit that patch. A throwing body rolls back the whole transaction. Existing
[A2 cancellation and shutdown rules](graphevo-2-async-transactions.md) still apply:
queued cancellation does not wait for the active writer; cancellation before
save rolls back; successful save returns its committed result.

Entity deletion removes incident directed relationships and removes the entity
from action endpoint sets, preserving other entities and valid empty actions.
Relationship/action deletion uses their facade cleanup for owned detail rows.
Partial patches preserve untouched properties, tags/groups, type and creation
metadata. New nodes receive the facade's creation time unless an explicit date
is supplied; adoption does not synthesize missing source creation dates.

`fetchAll(Model.self)` returns that type/kind ordered by UUID string. A3 uses a
linear in-process identity index assembled from facade reads, with no query-cost
or scalable paging guarantee. This is the explicit local foundation for A7,
not a silent fallback for an unsupported query operator. SQLite read scopes
retain A2's pinned-view contract; in-memory/native external-writer limits remain.

## Alpha layout a3.1

No native entity/attribute is added. The reserved namespace is
`__graphevo_v2.`. Application logical types and top-level property keys must not
use it. Collisions in v1 adoption fail before editing.

| Location | Stored value |
|---|---|
| One Entity with type `__graphevo_v2.graph` | Graph UUID under graphID; layout `a3.1` under layout |
| Every application Entity/Relationship/Action | Graph UUID under graphID and node UUID under nodeID |
| Adopted source nodes | Original v1 facade ID under legacyID |
| Every application node | A required encodedKeys string array identifying versioned property envelopes; empty for untouched adopted v1 values |

These names have the namespace prefix in storage. IDs are stored as canonical
UUID strings. Lookups never regenerate a missing ID, derive it from a Core Data
URI, or obtain permanent IDs as a side effect. Adoption reads old facade IDs
only as translation keys; those IDs do not become new identities.

The root is hidden from public records. Opening validates layout and all node
identities, including duplicates and graph ownership, plus the required property
format metadata. Unknown/corrupt versions
fail instead of creating another root or reassigning IDs. Metadata checks are
local integrity checks, not a distributed uniqueness constraint or import barrier.

## Versioned property values

New typed values are Data envelopes in the existing transformable property
rows. encodedKeys distinguishes them from ordinary v1 Data; payload bytes are
never recognized by a heuristic prefix. Unchanged legacy rows keep their
original encoding. A patch updates only named rows and their format bookkeeping.

The internal JSON envelope is version 1 with a frozen V1 payload implementation;
public GraphValue/GraphRecord still have no implicit Codable persistence
conformance. Future changes require an explicit envelope/layout version and
migration path. Each GraphValue case has an explicit payload tag, preserving
Bool versus integer, signed/unsigned boundaries, Decimal, dates, UUIDs, containers,
null and unknown codec/version bytes. Encoded payloads are retained, never run
implicitly. Nonfinite Double values are rejected before editing by the encoder.

This resolves explicit null/UUID/encoded writes for the new typed path. The older
plain GraphRecordMapper adapter retains its measured null restriction; it is not
the versioned storage path. Existing ambiguous legacy nil-backed values still
fail decoding visibly. PDF, image and custom v1 value conversion still need the
broader lossless source matrix before beta. Local adoption does not discard or
re-encode those untouched source rows; original backups retain their data.
Property envelopes trade native scalar queryability for exact values in this
candidate. A7 must measure costs and may motivate native scalar/index structures;
this is not a frozen final schema or query design.

## Legacy ownership exclusion

A shared, checked Sendable gateway lease reserves canonical resource keys before
native access. The runtime registry's owner UUID and the legacy gateway are
incompatible owners. Compatible public typed handles still share one native owner.
Different registry instances cannot independently open the same active resource.

Legacy leases attach to the native persistent coordinator using an Objective-C
association. Retaining a legacy context/coordinator therefore retains ownership,
even if its Graph wrapper disappears. A controlled internal handoff releases a
lease only after explicit native detachment; simply dropping a facade is not
proof of closure. Runtime final close releases its gateway lease after draining
and successful detachment; failed shutdown retains ownership.

The current legacy opening gateway refuses an adopted a3.1 store before publishing
readiness and detaches its temporary local container. This stops new writes
through this library's old facade. It cannot fence an old deployed library,
external process, manually reattached native coordinator or app-defined pre-init
side effects. Do not treat it as a cloud cutover mechanism.

## Explicit current-schema local adoption

```swift
let (store, report) = try await GraphStore.adoptLocalV1Store(
    at: existingLocalSQLiteURL, backupRoot: backupDirectory)
// report.graphID, report.nodeIDs[oldFacadeID], report.backupURL
```

The caller must stop all v1 and external writers, release their native resources
(or start a fresh process), and supply a quiescent current-schema **local** store.
This API does not infer a cloud destination from undocumented metadata and must
not be used as the cloud migration protocol. No personal/production store was
adopted during verification; tests use disposable fixtures.

Before the first identity edit, MigrationBackupManager copies the source SQLite
and present WAL/SHM to a distinct backup folder. Opening/preflight may already
have touched native metadata/SHM; this is a logical pre-adoption backup rather
than a promise that no byte has been touched since process startup. Backup failure
prevents identity edits. Source filenames, graph rows, native relationships,
actions, optional endpoints, tags/groups, dates and untouched properties remain.

All node UUIDs, old-ID mappings and the root are saved in one local transaction.
Failure/cancellation before save rolls back those edits, while a completed backup
may remain for recovery. If save succeeded but the caller lost the result,
repeating adoption recovers the same graph ID and mappings without stamping new
IDs or making another backup; backupURL is nil on that already-adopted path.
The backup itself remains available to open as a v1 store. No automatic restore
or destructive recovery is performed.

This is current-schema local identity adoption, not a complete versioned source
matrix, future model conversion, attachment migration or coordinated cloud
cutover. Those mandatory migration tracks remain in the delivery plan.

## Verification

The public Swift 6 ModelConsumer now performs real SQLite creation, typed fetch,
patch, close/reopen, identity recovery, unknown-payload retention and deletion.
Unit tests also cover multiple public handles, UI-state transfer, transaction
rollback, invalid patches caught by callers, cycles and endpoint changes, deletion
with surviving empty actions, reserved names, exact scalar/container payloads,
corrupt/duplicate IDs, unknown envelope versions, moved stores, ownership exclusion,
pre-adoption backups, source data/reference mapping and failed-backup rollback.

CI prepares its declared iOS 18.5 runtime and a dedicated simulator explicitly;
the runner image no longer provided that destination. This follows Apple's
[component download documentation](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).
The earlier PR failure was a missing destination, not a completed iOS test run.
Record final executed counts/platforms with the PR; local results do not certify
minimum runtimes, remote conflicts or replica recovery.

Local validation on 2026-10-26 with Xcode 27.1 / Swift 6.4 passed all 399 tests:
322 legacy, 46 runtime, 16 model and 15 public-store/adoption tests. All 77 new-stack
tests passed on iPhone 17 / iOS 26.5 Simulator without skips. The 15 public-store
and adoption tests passed under macOS Thread Sanitizer without reported races.
Both external package consumers passed. A separate Swift 6 typecheck deliberately
attempting to return GraphReadScope from read failed with its missing Sendable
conformance, confirming that ordinary consumers cannot transfer the scope as a
result. Manifest and diff checks passed. The earlier unreadable-store regression
was corrected to preserve the existing v1 error classification.


Two additional model golden-format tests verify exact version-1 envelope bytes
and reject unknown envelope versions; all 18 model tests passed after adding
these fixtures. CI initialization also selects the configured Xcode globally,
runs first-launch setup and boots the dedicated simulator before testing; bounded
retries cover only CoreSimulator service startup, never failing test bodies.


## Pre-merge review correction

Review on 2026-10-27 reproduced a silent representation error: removing a node's
encodedKeys metadata caused an encoded Data property to be returned as the raw
envelope bytes. The previous default of an empty key set conflated missing
bookkeeping with untouched legacy values. The regression failed before the fix,
including accepting a reopen of that incomplete store.

Every application node now requires an encodedKeys array. Local v1 adoption
writes an empty array in the same transaction as the identity mapping; insert
and patch retain their explicit arrays. Session validation rejects missing or
invalid arrays on open and on operations instead of returning successful
misinterpreted data. This finalizes the unreleased a3.1 contract before its first
integration; it does not add automatic conversion of earlier disposable branch
fixtures or change the native Core Data schema. Arbitrary payload corruption and
remote import completeness remain distinct verification concerns.

After the correction, all 402 local tests passed (322 legacy, 46 runtime,
18 model and 16 store/adoption). The 16 store/adoption tests also passed under
Thread Sanitizer without reported races, and the external typed consumer,
manifest and diff checks passed. The new regression's pre-fix failure remains
distinct from these post-fix results; platform CI verifies the reviewed head.
