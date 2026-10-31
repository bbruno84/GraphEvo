# GraphEvo 2 — T04 automatic CKAsset transport and async file delivery

Status: package-only increment on `codex/v2-cloud-assets`, directly from reviewed/
merged #115 (`8d88532`). Native S03, logical attachment identity/ownership and
public opening paths remain unchanged. Read with [A6](graphevo-2-attachments.md),
[T01](graphevo-2-record-transport.md) and [T03](graphevo-2-conflict-policies.md).

## Selected behavior

Attachments synchronize their complete content automatically. The maintainer
explicitly accepted eager asset transfer after checking Apple's API boundary:
CKSyncEngine fetch options do not expose desiredKeys. A record containing an
asset can arrive only with its downloaded content; metadata-first or on-demand
network transfer is not promised. The transfer awaits the framework outside
Core Data transactions, allowing UI and independent local operations to continue.
No second persistent cache/invalidation system is introduced.

Local readers retain the last complete committed attachment during an incoming
replacement. Import validates size/checksum and publishes metadata/content in one
native save. Failure preserves the prior value and retained inbox; it never
publishes partial bytes or mixed revisions. Ownership, immutable IDs, cascades,
whole-record conflict policies and delete-wins retain A6/T03 contracts.

## Wire format and portable recovery

Normal primitives retain wire format2 and format1 reads. Attachments use format3
on the same GraphEvoNode type, with one additional `asset` CKAsset field. The
internal payload describes attachment metadata and whether its local envelope is
legacy or split; application extras, tags/groups, endpoints, createdDate and
modifiedAt remain lossless. Content is excluded from the CloudKit Data payload.
Both existing local attachment representations round-trip without conversion.
Imports order entities, edges/actions, then attachments so an edge/action owner
can appear in the same complete cut. Missing dependencies refuse atomically.

SDK asset URLs are temporary and are never persisted. The portable archive codec
copies bounded asset bytes into its secure record snapshot before retaining an
incoming or sent envelope. Frozen outgoing snapshots likewise retain bytes.
When the native provider offers a batch, it materializes new private temporary
files and constructs CKAssets outside Core Data. Files stay alive until the
native send returns and are cleaned when that attempt finishes. Native server
conflict snapshots use the same portable boundary, including ambiguous-success
comparison of the entire body/date. Restored URL-bearing asset archives are
refused; no stale SDK path is followed during recovery.

Apple explicitly documents that serverRecordChanged's serverRecord has nil
fileURL for its asset references. Before retaining that conflict, the native
delegate asynchronously refetches the complete current server record outside
Core Data. A concurrent unknownItem is retained as a remote-deletion result;
other lookup failures stop the session with transportUnavailable and preserve
the immutable pending attempt for recovery. No metadata-only winner is committed.
This may add an explicit record fetch per asset conflict, without increasing the
two-native-send cap. See [Apple's fileURL contract](https://developer.apple.com/documentation/cloudkit/ckasset/fileurl?language=objc).

These portable snapshots deliberately duplicate bounded content for durable
retries instead of adding a sidecar-file journal in this increment. Original
bytes can therefore exist in application properties, a frozen attempt and an
engine envelope. All existing 32-MiB encoded transport/session budgets still
apply, with the existing receipt/deleted-ID limits. The per-file ceiling remains
10MiB, including empty files; archives enforce it before retaining bytes. A batch
that exceeds a budget fails explicitly without acknowledging its work. Reduce
maximumRecords rather than silently increasing budgets. This is not streaming,
a process-memory cap, a production size envelope or a native SQL placement claim.
Native external binary placement remains Core Data's decision.

Engine document3 and graph transport2 structures do not change: their opaque
archives now support portable format3 attachments. Old runtimes cannot consume
new asset records and no alpha downgrade is supported. Production CloudKit schema
deployment must add the optional asset field before activation. Mandatory v1
conversion, backup consistency and shared/account acceptance remain distinct.

## Async copy to the consumer

The package-only ContextManager entry point is:

```swift
func exportCloudAttachment(
    _ id: GraphNodeID, to destination: URL,
    configuration: GraphCloudConfiguration,
    timeout: Duration = .seconds(300)
) async throws -> GraphAttachmentMetadata
```

A verified local snapshot exports immediately without waiting for a newer remote
revision. If absent, callers share refresh work per graph and the underlying
fetch per database scope, then explicitly apply the retained graph inbox and
read a verified snapshot. Each caller exports to its own new destination through
A6's coordinated, exclusive atomic publication. No internal/native URL escapes.
The ordinary existing GraphStore attachment/export APIs keep their local snapshot
behavior; no new public custom-cloud opener is added.

Cancellation and a caller's positive configurable deadline stop only that wait.
They do not cancel shared engine work; other callers and eventual import continue.
Default timeout is five minutes and throws attachmentTimeout, rather than waiting
silently forever. A completed refresh without the requested node throws missingNode;
decode, dependency, account, permission and network errors propagate. This is not
a global synchronization certificate or automatic background scheduling policy.
No per-file progress, streaming, eviction policy or unlimited retry is exposed.

## Validation and follow-ups

Deterministic S03 tests cover zero/512-byte/10MiB files, actual provider CKAsset
materialization, portable recovery after SDK files disappear, legacy/split
replacement, owner/edge dependency ordering, both conflict policies, checksum
failure retaining prior data/inbox, no import feedback, caller cancellation,
shared refresh, timeout and independent local writes during a stalled fetch.
[Physical protocol](../../Experiments/CloudAssetProbe/README.md) and its result
separate real server behavior from injected receipts. Recheck resource costs,
real media, shared-account permissions, power loss/backup and production deployment
before closing broader post-alpha gates.

Apple references: [CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset?language=objc),
[fetch options](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchangesoptions),
[record fetch async API](https://developer.apple.com/documentation/cloudkit/ckdatabase/records(for:desiredkeys:)).
