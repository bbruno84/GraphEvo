# MF07 — explicit local v1 to S03 conversion

Status: package-only implementation on `codex/v2-local-v1-conversion`, based on
#128. This supplies the first bounded local conversion route, not automatic
public migration, a cloud cutover or completion of mandatory v1 acceptance.

## Admission and supported source

`GraphContextManager.convertLocalV1Store(at:to:graphID:operationID:backupsIn:reason:limits:)`
reads one existing v1 store and creates a distinct S03 destination. The caller
retains the GraphID and operation UUID before invocation, stops all v1/external
writers, and establishes that the local source contains the intended data. This
operation does not fetch the old cloud or certify completeness. No cloud session
is started. Existing default/current openers still refuse incompatible stores.

The supported source is the exact twelve-entity `GraphRuntimeSchema.current`
model. Unknown schemas, already adopted v2 layouts, reserved metadata collisions,
orphan/duplicate detail rows and unsupported values are refused. This increment
does not silently select historical model versions or migrate alpha stores.
Source and destination aliases must identify different resources. Existing native
or legacy writers exclude conversion through the runtime/gateway ownership rules.

A restricted `legacyReadOnly` runtime configuration enables stopped-source reads
without starting PH tracking or pinning query generations. Ordinary versioned
reads can fail on a v1 file that has not initialized those facilities. The mode
requires one standalone read-only local store, is incompatible with normal
reader aliases, and cannot admit writes. Only its structural validator also skips
query-generation pinning, after checking all native stores are read-only. Normal
v2 read/observation rules are unchanged. This is not cross-process exclusion;
external writers must already be stopped.

## Data and identities

The physical model addition alone is insufficient: v2 also needs stable UUIDs,
graph membership and typed property envelopes. Conversion reads with the old
model and creates the new graph with normal Node/Session operations. It never
relabels or replaces the source SQLite, moves native objects between contexts,
transplants old PH or imports native CloudKit identity/transport metadata. This
uses the source/destination separation described in Apple's
[migration process](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmMigrationProcess.html).

Preserve Entity/Relationship/Action kinds, types, all supported properties,
tags/groups, optional endpoints/empty action sets, dates and native per-property
`appDataVersion`. Retaining that legacy attribute does not activate version
admission or add a cloud/application version field. Missing creation dates remain
absent; legacy modification dates are unknown rather than invented.

Fresh random graph-aware node UUIDs are persisted with a legacy-ID lookup map and
reserved native receipt in the destination. They are not derived from Core Data
URIs. A canonical source fingerprint covers legacy lookup IDs, contents,
references, dates, tags/groups and legacy property versions, independently of
new UUID allocation or keyed-archive ordering. Retry recovers the committed map;
a changed source, another operation or an unrelated destination is refused.
Existing mapped nodes must retain the matching legacy key; legitimately deleted
nodes are verified against retained deletion IDs. Later ordinary v2 edits are
never overwritten by a repeated conversion.

Foundation scalar/container/date/URL/binary values retain their GraphValue shape.
Known historical AnyCodable wrappers can use an opaque
`GraphEncodedValue(codec: "GraphEvo.v1.secure-archive", version: 1, data: ...)`,
decoded explicitly with the existing `GraphArchiver.unarchive` whitelist. Their
semantic fingerprint is separate from archive ordering. Existing archived Data
is retained as Data, without guessing that it is JSON, an image or an attachment.
There is no application format registry. Ambiguous legacy nulls/absent native
values and unknown classes fail rather than silently losing a property. A null
is converted only when the platform exposes it unambiguously. Historical native
wrapper-store fixtures still need production-source acceptance; current Core
Data can refuse writing those wrappers directly because they lack NSCopying.

## Backup, commit and recovery

After source validation and before creating a new destination, the central
BackupManager makes/verifies a complete legacy `.geb`, including external binary
content. It accepts one explicit internal legacy-schema validator in addition to
its native S03 validator; this is not a consumer codec registry. The immutable
`__graphevo_v1Conversion.json` artifact binds operation/graph, physical source
identity, source store UUID and fingerprint. The operation UUID fixes the backup
ID; retries verify/reuse the same package rather than overwrite it. Pin the backup
durably before publishing. Archive verification/restoration understands both
supported physical models without auto-activating a restored graph.

Initialize the destination root, identities, final application records, normal
local-author PH and format-1 native receipt in **one transaction**. No GraphStore
is returned or made available by conversion before that commit. Before-save
cancellation/failure rolls back application effects and keeps the backup pinned.
An uninitialized S03 file/purpose marker can remain after rollback; retry accepts
it only without native rows and without a conflicting purpose. It is not a ready
graph and normal opening refuses it.

After commit, the native receipt is authoritative even if the caller lost the
result. Repeat the same explicit request to recover it, including after later
v2 edits. The source must still match the recorded identity/fingerprint. Current
source/destination/backup URLs are supplied again; none is serialized. Same-volume
relocation is supported; copied/replaced sources are refused.

`GraphV1ConversionResult` contains the receipt, current backup URL and
`cleanupPending`/`cleanupFailure`. Successful data commit stays successful after
cancellation or native-detach/unpin failure, but pending cleanup is not a ready
Graph certificate. Failed detachment retains runtime claims and may require
process restart. Precommit cleanup failures retain both the original failure and
cleanup failure. Successful cleanup releases only this operation's backup pin.
Call the existing awaited `openGraph(id:at:)` after conversion/cleanup to enter
the ordinary lifecycle; there is no automatic public-opening interception yet.

## Bounds and remaining gates

Defaults: 10,000 application records, 100,000 source native rows and 32 MiB
weighted logical payload; hard payload maximum 512 MiB. A conservative native
preview (`source rows + 5 × records + 128`) and the actual final transaction must
fit the normal 100,000-change PH limit. The legacy mapping is capped at 3 MiB and
the receipt at 4 MiB. Limits are atomic refusals, not a total heap/time/SQL-I/O
bound or an authorization for partially populated destinations. Larger staged
conversion needs its own recovery contract.

No new schema column, cloud node/asset format or session format is introduced.
A local binary property can exceed the existing inline cloud-record allowance;
local preservation does not certify remote publishability or reinterpret it as
an attachment. Large-property handling before cloud activation remains an
explicit v1 acceptance gate. Source completeness, actual production/historical
fixtures, paired stores, public bootstrap integration, account/device cloud
activation, physical kill/power-loss, external-process writers and scale remain
open. Backups created by abandoned failed conversions remain retained until an
explicit retention decision. No beta/stable migration gate closes here.
