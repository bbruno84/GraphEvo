# GraphEvo 2 — File synchronization

The current S06/S07 property and attachment contract advances the descriptor,
node, session, transport and asset-reference formats described below. See
[properties and attachments](graphevo-2-property-attachments.md); earlier format
numbers in this document retain their historical increment scope.

Status: integrated through [PR #190](https://github.com/bbruno84/GraphEvo/pull/190),
following the local File increment in
[PR #189](https://github.com/bbruno84/GraphEvo/pull/189). Read with
[File lifecycle](graphevo-2-attachments.md#local-file-primitive-candidate),
[durable assets](graphevo-2-durable-asset-spool.md) and
[record transport](graphevo-2-record-transport.md).

## Opening and representation

`GraphContext.localFiles()` selects the File-aware schema and now supports
the ordinary `connectCloud(using:)` entry. The native schema and its
identifier from #189 are retained. The default context keeps its existing
schema. GraphEvo migrates native storage; consumer interpretation and data
conversion remain application work. Migration of a stopped, unbound S04
store establishes a new persistent-history baseline in the destination and
queues its retained nodes for first publication.

`GraphRecord.file` contains fixed `GraphFile` metadata when a File is
materialized. The metadata type belongs to GraphEvoModel and remains
available through the public product. Relationships and actions retain
UUID endpoint references.

A File uses the existing `GraphEvoNode` record type and fields, with
`format = 4`, `kind = "file"`, fixed metadata in the payload and content in
the existing `asset` field. Its properties dictionary is empty. No CloudKit
record type or field is added. Attachment format 3 and its 10 MiB ceiling
remain in force.

File-capable native sharing publishes a format 2 graph descriptor. A
preceding reader rejects it before discovering the shared graph. The
preceding node decoder also rejects File record format 4. Current
contexts with the ordinary schema refuse File asset delivery. Unsupported
changes fail before their route is acknowledged as applied.

## Durable files and transaction boundaries

The public `importFile(from:name:contentType:configuring:)` overload lets consumers
create links or other graph edits with the new File in the same transaction.
Its callback is synchronous, context-confined and invoked once. The imported
File must remain present with its returned fixed metadata. Failure rolls back
all graph edits; the existing reclamation path handles unreferenced prepared
content. It does not add a file-owner rule or change transport/schema formats.


Outgoing preparation snapshots the file metadata and copies the exact
immutable revision into the existing store-scoped spool under writer
admission. The durable reference binds the account, container, environment,
graph, zone, record, native store and PH epoch. Its optional `isFile` flag
distinguishes file contents from bounded attachment contents. Published
attempts contain compact envelopes and references. Replacement and
reclamation of permanent content cannot invalidate a frozen attempt.

The native outbox verifies the retained file and assigns a `CKAsset`
constructed from its URL. An SDK source URL received in a native callback
is transient and cannot be encoded in an incoming document. The session
copies that file to its owned incoming spool before publishing the inbox
or sent receipt. Frozen activation inventories use the same path.
The ordinary engine fetch includes CKAsset content. Download is eager with
synchronization, while `withFileURL` only accesses the resulting local file.
Bounded buffers avoid whole-file materialization; they do not provide lazy
network retrieval or a public download policy.

Application verifies the incoming reference and copies its content to an
immutable permanent revision before the native transaction saves its
reference. Conflict policy and deletion history are resolved by the
existing writer transaction. Failure retains the inbox and the previously
committed file. A published file whose transaction fails can be recovered
or reclaimed as an orphan. Referenced incoming files are deleted after
durable consumption. Frozen outgoing files are released after the
corresponding graph receipt commits.
`reclaimFiles()` is local maintenance under the existing store writer grant.
Read-only CloudKit participants may remove unreferenced local revisions;
this neither modifies graph records nor grants permission to replace content.
Terminal leave/access-loss purge removes permanent revisions, abandoned
preparations and the store-scoped outgoing spool after exact native identity
validation and exclusive Apple deletion admission. Content removal precedes
SQLite destruction so interruption cannot leave unowned bodies after losing
the database identity. Cleanup is idempotent; failure retains the terminal
purging state and store registration for retry. Consumer exports and other
native store generations are excluded.
After durable session purge, staged incoming assets no longer referenced by
any remaining graph are removed through the ordinary spool cleanup path.

The permanent revisions and frozen outgoing spool are included in
`copyLocalFileGraph(into:)`. Restore uses a File-aware context. Existing
generic backup and migration-workspace paths continue to refuse this
schema until they implement the same file ownership.

## Limits

The native CKAsset ceiling is 50,000,000,000 bytes. Source length is checked
before copying and during streaming. Local import may still hold a larger
file that CloudKit refuses. Preparation reports the transport failure and
keeps local data. Apple confirms this ceiling subject to remaining iCloud
storage. [Apple framework engineer clarification](https://developer.apple.com/forums/thread/827897)

The existing 250-operation and estimated request budgets apply to record
envelopes. The 32 MiB asset preparation window can admit one larger File
on its own, allowing later attempts to progress. File bodies are copied
and hashed in bounded chunks. Full transfer, copy and verification time
and temporary disk use scale with content length. Current copying retains
the graph writer admission.

## Verification

Controlled tests exercise a 25 MiB frozen attempt across replacement,
reclamation and reopening, a durable incoming restart, exact file metadata,
relationships, tags and groups, deletion, corrupt inbox recovery, native
server-conflict application, physical-kind retention after tag/group
removal, shared-scope read-only enforcement, public context configuration,
and the native asset size preflight.

Local verification passed 627 store tests, 91 runtime tests and 30 model
tests on macOS. The focused iOS simulator checkpoint passed 36 tests across
File sync, local files, assets and native v1 migration. A subsequent native
outbox adjustment passed the 51-test macOS transport/File/asset subset and
the 23-test iOS File/asset subset. Manifest validation and `git diff --check`
also passed. Remote CI was not requested for this alpha increment.
The [pre-merge review](results/file-sync-review-2026-11-07.md) adds read-only
reclamation and terminal-purge regressions, including retained incoming assets
and interrupted cleanup. Its final checkpoint passes 752 macOS v2-profile
tests and 61 affected iOS simulator tests.

The [private iPad checkpoint](results/file-cloud-ipad-2026-11-07.md)
exercises actual CloudKit upload, an empty independent SQLite replica and
replacement after closing and reopening both contexts. It uses one physical
iPad and sequential sessions for the same account. The
[iPad/XR sharing checkpoint](results/file-cloud-shared-devices-2026-11-07.md)
adds physical cross-account import, replacements in both directions,
persisted join recovery, read-only enforcement and deletion. A sender
SIGKILL at the native provider boundary retained the exact 128 MiB attempt;
after an unclassified first resume failure, a diagnostic continuation sent
it successfully and the XR verified its content. A fresh repeat captured
`serviceUnavailable` (6) and three seconds of native retry advice; the
existing automatic scheduler subsequently settled the retained attempt,
and an empty XR replica verified the 128 MiB content. Measured midstream
interruption remains a separate acceptance gate.
