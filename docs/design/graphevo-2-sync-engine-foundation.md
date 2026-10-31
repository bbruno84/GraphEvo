# GraphEvo 2 — shared engine sessions and durable incoming events

Status: package-only implementation on `codex/v2-sync-engine-foundation`, based
on reviewed/merged #108 (`0ddd613`). The native model remains S03. The [T01 continuation](graphevo-2-record-transport.md)
now supplies manual transport/effect receipts and a path-free format-2 session
document; the initial #109 checkpoint below retains its historical scope. That
checkpoint introduced no public opener, wire format, record upload or application import. The retained
CS01/PH01 experiments are evidence; their implementations are not merged.

## Session ownership and API

GraphContextManager owns explicit sessions configured with container, environment
label, canonical local state directory and limits. `startCloudSession` verifies
the current iCloud user and starts one private CKSyncEngine; the shared engine
starts when a shared zone is bound or shared state/bindings are restored. Native
entry points require iOS 17/macOS 14 and refuse app-extension activation. Package
platform floors remain iOS 16/macOS 13. Local-only use remains independent.

Concurrent matching starts share one opening task. Cancellation before admission
refuses the caller; an admitted shared startup continues independently of waiter
cancellation. A process-wide reservation covers the whole configured container
before account verification: another manager cannot create duplicate engines,
even by supplying another account/environment label or state directory. The
native environment still comes from signing entitlements; the configuration label
namespaces persistence and does not switch or prove the server environment.

An OS lock on `session.lock` excludes other owners of the same state directory,
including another process. Never unlink that lock file while owners can exist.
This is not a global cross-process CloudKit database lock across arbitrary
state directories. Applications must designate one synchronization process.

Package-only operations start/stop a session, bind a zone, request a scope fetch,
inspect status, look up a binding and read a bounded inbox prefix. No CloudKit
native type is added to the public API. One fetch per database scope is admitted
at a time; a duplicate reports busy without blocking the other scope's callbacks.

## Zone routing

Bindings use the full database scope, zone owner and zone name. Each zone and
graph occurs in at most one binding within a session. T01 persists no file URLs:
after restart the app registers the current store URL by opening the graph.
Runtime comparison keys must never be reused as filesystem paths. Binding requires
an open exclusive coordinator and validates its graph/store identity and purpose. No zone/share is created in CloudKit.

Manual fetches request the bound zone IDs. Database discovery events and any
unknown-zone events delivered by the engine are retained without creating graphs
or applying records. Bindings remain after graph leases close; runtime locations remain in the same
manager only. T01 import reacquires and validates the registered coordinator;
a restored route does not supply a local file location.
Closing a consumer does not stop shared transport or erase pending local work.

## One local state document

The state directory contains `session.json` and its persistent lock file. The initial #109
format-1 document stores container/environment/account identity, private/shared
engine serializations, bindings and an ordered incoming inbox. It is separate
from every graph's hidden-root Persistent History checkpoint and never uploaded.
Do not mix either checkpoint with the legacy migration journal.

Each received event is persisted by atomic document replacement before returning
from the serial engine delegate. A later state update replaces the same document
with both engine states and the already persisted inbox. Events are never removed
in this increment. CKRecords use secure archives with system fields; identity is
checked against the detached envelope on reception/reopen. Application values
are not decoded as GraphRecord. Zone deletion reasons and typed record deletions
remain explicit events; record deletions are not synthesized from missing rows.

If interruption happens after inbox publication but before engine-state
publication, restart restores the older engine cursor plus the received events.
Fetched events may repeat and get distinct local envelope UUIDs. This is at-least-
once retention, not exactly-once application or deduplication. Future import
must establish its effect/acknowledgement protocol before inbox consumption exists.

Limits default to 4,096 incoming changes and 32 MiB for the complete encoded
state document, configurable at startup. The inbox is read-only, so it can fill
until a later implementation supplies application/consumption. These are retained
count/document-size limits, not total heap, I/O, execution-time or archive-decoder
bounds. Full document rewriting is intentionally a first bounded implementation;
measure it before selecting a production resource envelope.

## Failures and shutdown

Corrupt/incompatible documents, account mismatch and invalid secure archives are
refused without reset or erasure. Persistence errors, limit failures, unsupported
assets and unexpected upload events block the live session. Later state updates
are ignored, retaining the last successful cursor. A fresh explicit startup after
successful stop reuses that cursor/inbox; no automatic reset/retry loop exists.

CKAsset fields, including encrypted values and arrays, are refused before archive
publication. This increment does not persist temporary asset URLs or claim file
recovery. No outgoing database/record changes are scheduled, automatic syncing is
disabled and the upload delegate returns nil. Record codecs, asset staging, PH
batch acknowledgements and end-to-end synchronization are subsequent work.

An account change invalidates both scopes; old data is retained under its original
identity, never relabeled for the new account. No account identifiers, record
payloads or engine serializations are logged. Status reports bounded typed failures.
Network fetch errors propagate to the requester and do not themselves reset state.

Stop prevents admission, cancels engines outside delegate callbacks and drains
admitted fetches/callbacks before releasing drivers, the directory lock and the
process reservation. Late callbacks after completed stop are ignored. Duplicate
stop callers await the same cleanup. Failed cleanup retains claims and returns
the same failure; failed startup cleanup is quarantined in the manager. Starting
again must not discard a blocked/closing session's registration. Dropping the
manager schedules the same cleanup; explicit awaited stop is the reliable barrier.

## Validation and acceptance boundaries

Tests use an injected driver/account provider and actual native graph stores.
They cover coalesced/cancelled starts, process-wide and cross-process directory
exclusion, exact zone routing, lazy/restored shared engines, graph closure,
immutable retained events and both state serializations, checkpoint-write failure,
limits, unknown zones, account change, invalid bytes/namespace/secure identity,
busy fetches, shutdown draining/late callbacks and failed-cleanup quarantine.
Native secure archive and asset-refusal tests use CKRecord without network access.

The full local checkpoint passes 616 tests (331 legacy, 191 store, 71 runtime,
23 model). The selected iOS Simulator 26.5 run passes 55 functions / 65 expanded
cases across engine, PH pending, coordinator and resource-group suites; the
macOS-only independent-process lock test is not counted there. The new engine
suite has 21 macOS functions / 22 expanded cases. The Swift 6 consumer, package
manifest and diff checks pass. Remote exact-head CI remains required for integration.

These tests prove the application persistence/lifecycle protocol, not physical
CloudKit delivery or real power-loss durability. No test container reset or device
mutation is needed for this increment. Retain physical engine/callback evidence,
actual crash/power-loss, resource measurements, full incoming effect/acknowledgement,
assets, account/conflicts, graph pause and public activation in the beta/stable gates.

Apple references:
[one engine per database](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/database),
[serial delegate events](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8/handleevent(_:syncengine:)),
[state/data ordering](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate),
[manual scheduling](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/automaticallysync).
