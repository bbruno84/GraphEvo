# GraphEvo 2 — A6 native attachments

Status: alpha implementation candidate. Read with section 8 of the
[specification](graphevo-2-specification.md), [A5 sharing](graphevo-2-user-sharing.md)
the [probe procedure](../../Experiments/A6NativeProbe/README.md) and the
[retained results](results/a6-native-attachments-2026-10-27.md).

## Representation and ownership

An attachment has a stable graph-scoped `GraphNodeID`, exactly one application
node owner, a filename, opaque content-type identifier, byte count, SHA-256 and
revision UUID. Owners may be Entity, Relationship or Action objects in the same
graph. Attachments cannot own attachments; ownership cannot be transferred by
replacement or a raw patch. Filename metadata is a component, never a storage
path. The default content type is `public.data`; the host chooses a more precise
identifier. Existing v1 binary properties are not automatically reinterpreted
as owned attachments. Older alpha readers do not implement this ownership/cleanup
contract; downgrading an A6 attachment-bearing store to those readers is unsupported.

The candidate reuses an Entity with logical type `GraphEvo.Attachment.v1` and
one `content` property. A versioned binary property-list envelope holds metadata
and bytes together; the existing versioned value codec then stores it through
Core Data's transformable property, which already permits external binary
storage. The native model/hashes are unchanged. The logical type/content format
is reserved for this feature. This is a deliberate alpha representation to
exercise files on the current schema, not a final schema commitment or a claim
that the OS chose physical external storage.

One native property value binds metadata and bytes; reads still verify its
version, graph/node identities, owner, size and checksum. Full sharing integrity checks validate file content as well;
control-only access reduction remains available without decoding that content.
An unavailable owner,
missing value or mismatched content fails visibly. Such a failure during cloud
import does not establish permanent corruption. Native snapshots are separate
from application-model decoding and from cloud import completeness.

## Lifecycle

```swift
let metadata = try await graph.importAttachment(
    from: sourceURL, ownedBy: documentID,
    fileName: "photo.jpg", contentType: "public.jpeg")
let content = try await graph.attachment(metadata.id)
let updated = try await graph.replaceAttachment(metadata.id, from: editedURL)
try await graph.exportAttachment(metadata.id, to: applicationDestination)
try await graph.deleteAttachment(metadata.id)
```

Import uses coordinated, security-scoped source access outside a context/write
scope. It reads bounded chunks into owned memory, never a mapping or retained
source URL. The source can subsequently disappear. Complete prepared content
enters the existing transactional/native-sharing path, with owner validation
repeated before mutation. A source/preparation/cancellation failure leaves the
graph unchanged.

Replacement preserves ID, owner, creation date and unmodified record fields.
It prepares new bytes outside the write scope, then checks that the current
revision matches the previously observed one. A local intervening replacement
fails with `conflict` before edits. The local transaction commits new metadata
and content together, or retains the previous committed value. This revision
check is not a distributed conditional cloud save or a conflict-resolution
policy for remote concurrent updates.

Deletion removes the attachment node and owned details. Deleting its owner
also deletes the attachment. Dependency planning includes files owned by edges
implicitly removed with an endpoint. It validates affected dependencies and
native delete advice before editing, and preserves the existing behavior of
surviving actions/endpoints. Transaction failure rolls back all these removals.

Read results are detached `GraphAttachmentContent` values with complete bytes.
`attachments(ownedBy:)` lists detached metadata in stable node-ID order. Both
listing and reading currently decode/check complete content; metadata listing is
not yet a cheap projection. Synchronous read scopes expose the same read/list
operations. File I/O is not allowed inside a mutation scope.

Export snapshots and verifies content first, then coordinates a write at a new
caller-selected file URL. It prepares a temporary sibling before publishing;
existing destinations are refused. Temporary artifacts are removed on failure.
The caller owns and cleans up the completed export. No temporary-export cache
or reference to a Core Data internal URL is returned.

## Mirroring and partial operations

Owner-private imports use normal typed transactions and graph membership.
Participant imports create a complete detached attachment and use A5's explicit
existing-share assignment, including every owned native detail row, before
linking it to the live graph. Finalization revalidates logical dependencies
after assignment; a remotely removed owner cannot be silently replaced with
an orphaned file. A missing owner after assignment retains intent and requires
reconciliation; automatic abandonment/garbage collection of that partial case
remains release work. Native errors may already have persisted objects:
inspect `pendingSharedOperations()`, recover the recorded operation and obtain
its attachment metadata by the returned IDs; do not resubmit the import.

Replacement changes the existing content property and therefore uses the
ordinary permission-checked transaction rather than creating new shared rows.
Deletion uses the same ownership and native permission checks. Account/cache
policy and remote conflicting replacements remain release gates. No direct
CKRecord/CKAsset mutation, custom sync engine, manual external-file management
or selective download is introduced.

## Memory, availability and backup

The alpha enforces at most 10 MiB of original content per attachment; empty
files are supported. This is a library envelope, not an Apple limit. Although
source reads use chunks, content/encoding/native mirroring can buffer complete
copies. There is no streaming API, per-file progress, eviction control,
persistent offline-retention guarantee or global synchronized status. Publish
measured device windows with the retained hardware result; larger envelopes
and representative production content remain beta validation.

Use `GraphStoreBackup.copyClosedDirectory(from:to:)` for a whole-content local
copy. The source directory must contain the complete application-owned native
store layout, including both resource files, every native auxiliary artifact
and local operation ledgers. Close **all** handles, stop external writers and
control the destination before invoking it. The helper does not discover or
certify quiescence, pause CloudKit or attest remote delivery. It copies the
whole directory opaquely to a temporary sibling and publishes at a new,
non-overlapping destination. Reopen the copied layout to restore/verify it.
Local SQLite copy/reopen is tested; mirrored-group restore against cloud data
remains unverified and is not a cloud rollback protocol.

`MigrationBackupManager.backupStore` remains a narrower SQLite/WAL/SHM/ledger
copy; it does not discover external attachment content. Existing migration
callers must adopt a whole-content source backup before transforming stores
that contain external content. Coordinated v1 cloud cutover remains separate
mandatory work; this increment neither silently migrates data nor freezes the
schema.
