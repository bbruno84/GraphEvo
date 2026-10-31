# GraphEvo 2 — CF01 logical cloud record format

Status: package-only codec on `codex/v2-cloud-record-format`, based directly on
reviewed/merged #109 (`e26a0cd`, exact-head CI `41143330378`). Maintainer decision
M19 selects one CloudKit record per logical Graph primitive with serialized
properties. Native S03 and its twelve entities remain unchanged. This increment
provides conversion boundaries. The separate [T01 continuation](graphevo-2-record-transport.md)
connects manual upload/import workers and receipts; CF01 alone does not activate them.

Attachments are subsequently supported by [T04](graphevo-2-cloud-assets.md):
wire3 adds CKAsset content with portable durable snapshots. The original asset
refusal below describes the historical CF01 scope.

Current wire format is extended by [T03](graphevo-2-conflict-policies.md): format 2
adds an internal optional modifiedAt; format 1 remains readable with unknown date.
The original format-1 description below is historical where superseded.

## Record shape and identity

A zone is bound to one graph by the ContextManager. One Entity, Relationship or
Action becomes one `GraphEvoNode` CKRecord; no native property/tag/group row,
root/membership control, PH generation or local checkpoint becomes a cloud record.
Application logical types use the `type` field, not new CKRecord types per model.

| Field | CF01 representation |
|---|---|
| `recordType` | `GraphEvoNode` |
| Record name | `node.` followed by the canonical lowercase logical node UUID |
| Record zone | Exact zone name/owner from the trusted database-scope binding |
| `format` | NSNumber integer 1: library transport version, never app-data version |
| `graphID`, `nodeID` | Canonical lowercase UUID strings |
| `kind` | `entity`, `relationship` or `action` |
| `type` | Nonempty application logical type |
| `payload` | Deterministically encoded JSON Data body |

The body contains properties, tags, groups, endpoints and optional application
createdDate. Properties map their original keys to versioned GraphValueCodec
bytes. This reuses the existing lossless logical value envelopes, including the
binary Data envelope, not the physical native store layout. Public GraphRecord
and GraphValue do not gain Codable conformance. Changes to the shared value codec
must preserve CF01 decoding/encoding semantics or explicitly revise the transport
format; a native schema change alone is not permission to rewrite the wire format.

A literal missing property differs from a present GraphValue.null. Signed and
unsigned integers, Decimal, nested collections, Data, dates, URLs, UUIDs and opaque
consumer encoded values retain their types/bytes. Unknown consumer codec identities
remain opaque; no consumer format registry or global application-version gate
returns. Unsupported transport/property envelope versions fail visibly.

Relationship endpoints are optional UUIDs. Action subjects/objects are UUID
arrays, sorted for deterministic encoding and checked for duplicates on decode.
References inherit the bound graph identity; construction does not certify that
the targets have arrived or are entities. Tags/groups are sorted sets, with
received duplicates rejected. Missing createdDate remains nil, independently of
CloudKit's own creationDate system field. Native Graph validation/target resolution
still belongs to application of an incoming effect.

The explicit graph/node UUID naming protocol belongs only to the new custom
backend. It does not reinterpret v1/CD_* cloud records, derive legacy mapping API
results or convert existing mirrored stores. Account/container/environment and
database scope come from the engine session; a raw CKRecord itself does not prove
its database scope, source account or server acceptance.

## Validation and metadata

Reject unknown record types, fields, encrypted user fields, transport versions,
wrong canonical record names, graph/node mismatches, foreign zones and mismatched
kind/body shapes. Reserved `__graphevo_v2.` controls/properties never enter the
payload. `GraphEvo.Attachment.v1` saves are explicitly unsupported until CKAsset
transport is implemented; do not fall back to embedding attachment content here.

Decoding returns a detached GraphRecord plus securely encoded native system
fields. Re-encoding can restore those fields and replace the application body;
require the exact native record type/record ID before reuse. Invalid or foreign
metadata is refused, never silently replaced with a new record. Native change
tags are preserved by Apple's system-field coder, not fabricated from PH
transaction generations. The codec does not persist server metadata or resolve
serverRecordChanged; that persistence must be part of the next effect/receipt
protocol before real upload acknowledgements are enabled.

Defaults are 512 KiB encoded payload, 4,096 properties, 4,096 entries in each
bounded tag/group/endpoint collection and 64 KiB encoded system fields. Limits
are configurable and refusal returns no partial record/batch. These limits do
not bound total allocations, nesting work, batch bytes, header strings, secure
archive size or CloudKit's total server record size. They are not a claim of a
supported production payload envelope. GraphValue serialization errors propagate
as invalid records; data is never truncated or implicitly converted to assets.

## PH and inbox integration boundaries

GraphStore has a package-only prepareCloudBatch helper over the existing immutable
PH attempt. It preserves attempt ID, logical operations and generations. Saves
carry secure CKRecord archives; deletes carry the canonical record name without
inventing a body. Validate unique identities, graph ownership, operation/body
consistency and native-kind/logical-kind agreement before returning an artifact.
The raw native kind remains local discovery metadata and is absent from CKRecord.

Encoding failure abandons only the newly prepared in-memory attempt. Durable
pending work is retained and can be prepared again. Cleanup uses the captured
session directly so cancellation or concurrent collection cannot strand the
unpublished active attempt. Failure before preparation
must not abandon somebody else's active attempt. Successful conversion neither
acknowledges the attempt nor sends it; the caller must eventually acknowledge
actual successes or abandon it. The detached artifact is not network admission,
proof of a live coordinator or a durable sent receipt.

The decoder accepts incoming inbox envelopes using the complete trusted scoped
zone binding, validates secure archive identity and returns save/delete/zone events.
Unknown routes are not inferred from graphID fields. Zone deletion remains an
explicit event; missing records are not deletion evidence. Conversion neither
writes GraphStores, removes inbox entries, updates PH queues nor advances an
engine cursor. Incoming effects, dependency staging, idempotent receipts and
inbox consumption are the next increment.

## Queries, migration and open gates

CloudKit sees scalar identity/kind/type headers and an opaque payload. No remote
query backend or indexes are deployed by this increment. Payload properties remain
locally queryable through existing GraphEvo queries; they are not server-side
query fields. The typed-property-row alternative was discussed and deferred;
it does not authorize a new S03 revision or a second wire representation.

CF01 is a fresh custom-sync alpha protocol, not the native-mirroring schema or a
v1 conversion. No server deployment, device mutation, cloud reset, native migration
or public API change occurs here. Mandatory v1 data conversion/cutover remains
open. Later schema deployment must configure native CloudKit record fields and
indexes and validate the exact server representation independently.

Tests exercise all three primitives, every GraphValue case, exact numeric cases,
nil dates/null/absence, deterministic/fixed minimal wire shape, unknown/corrupt
versions, duplicates, foreign routes/identities/metadata, archive/system-field
round trips and refusal limits. An actual S03 coordinator/PH fixture proves failed
conversion retains pending work and releases its attempt, successful conversion
is immutable, old acknowledgements preserve newer edits and deletes need no body.
No server change tag is fabricated or physical cloud delivery claimed.

The local suite passes 630 tests (331 legacy, 205 store, 71 runtime, 23 model),
including 14 CF01 functions / 28 expanded cases. The Swift 6 consumer, manifest
and diff checks pass. Local tooling is Xcode 27.2. A generic iOS Simulator SDK build and the selected
iOS Simulator 26.5 suites pass: 69 functions / 93 expanded cases across CF01,
engine, PH pending, coordinator and resource-group suites. The initial simulator
attempt failed before build/tests because CoreSimulator was older than the
installed Xcode. Service/setup attempts were stopped while initialization was
blocked; after the maintainer restored Xcode setup, enumeration and test execution
succeeded. Remote iOS/macOS exact-head CI remains required before integration.

Next: persist native server metadata with successful send effects, connect upload
receipts to the existing generation-safe PH acknowledgement, and implement
transactional incoming insert/update/delete plus effect receipts before inbox
consumption. Add real-device private sync, conflicts, dependencies and restart
checks before acceptance; retain assets, sharing, automatic scheduling, pause,
account and power-loss/resource gates in the post-alpha checklist.
