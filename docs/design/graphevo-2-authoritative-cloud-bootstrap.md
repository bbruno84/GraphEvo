# MF10 — authoritative new-cloud activation after local v1 conversion

Status: proposed implementation contract, 2026-11-02. No implementation,
physical acceptance or public API activation is claimed. This follows
[MF09](graphevo-2-local-v1-bootstrap.md) on the S04 custom-sync runtime.

## Bounded outcome

Activate one selected, validated local conversion into one new owner-private
cloud graph. Other devices recover its existing logical identities and data into
empty replicas. They do not convert their local v1 copies into that cloud graph.
One conversion's native receipt/map remains the local authority for recovery.

The first implementation excludes existing populated destination zones,
participant-origin conversion, initial sharing, automatic source discovery,
authority transfer to another native store and public/default opening. Existing
graphs without this activation protocol keep their current behavior. MF10 does
not merge old native-mirroring zones with the new serialized-record layout.

## Cutover prerequisites

The host supplies a stable GraphID and one exact container/environment/account/
private-zone route for this migration. Every participating device must use that
same route. A caller selecting a different GraphID or zone creates a different
destination; the library cannot discover that two such requests represent the
same application dataset. The host must persist/distribute this selection before
allowing conversion or peer recovery, without logging private account data.

Before activation the host explicitly records its cutover decision: which source
is authoritative, how pending v1 writes were reconciled, why its local contents
are complete, which writers were stopped and how returning old clients are
prevented from resuming normal writes. Missing prerequisites leave activation
blocked. A supplied declaration records the host's decision; it is not library
verification of all old clients, remote completeness or a distributed v1 fence.

Old-cloud data remains protected. A late v1 edit requires explicit application
reconciliation; MF10 never automatically imports it or restarts conversion.
Production cutover acceptance remains open until the host policy is exercised.

## Local preparation and immutable seed

ContextManager reserves GraphID, canonical resource and activation generation,
using existing ownership, local-maintenance and per-graph sync admission. Drain
admitted operations, block consumer mutations and prohibit target transport or
sharing until authority is resolved. Unrelated graphs retain local/cloud progress.
Preserve pre-existing manual pauses and reservations when releasing owned holds.
Persist the native activation marker before releasing preparation admission, so
ordinary reopening cannot bypass the hold while a session is stopped or starting.
Validation failure before any remote claim releases only the request's holds.
A definitive foreign-claim refusal can restore local-only editing while retaining
the cloud conflict; an uncertain or owned claim retains activation admission.

Require the selected S04 native conversion receipt, matching target store UUID,
complete mapping and ordinary structural/payload validation. Bind a new stable
activation UUID to that receipt and the current native store/PH epoch and route.
Later legitimate local v2 edits before activation are included in the selected
seed; never rerun conversion to obtain the initial cloud body.

Under the write hold, preflight every current primitive through the actual
CF01/T04 encoder and current bounds before creating remote application records.
Persist a canonical seed manifest: sorted logical IDs and kind/type plus a digest
of each deterministic encoded logical body and attachment content digest/length.
Define the exact versioned canonical byte encoding with codec tests before
implementation review. Include optional dates, tags/groups and endpoints; counts
alone cannot validate the seed. Bound the manifest and total preflight work with
explicit limits and refuse atomically. No new unbounded inventory is permitted.

Ordinary Data stays an ordinary property. A value exceeding the existing 512-KiB
default encoded primitive payload allowance blocks activation; MF10 never raises
the limit, truncates data or implicitly turns it into an attachment. Explicit
consumer transformation, if needed, precedes preparation and semantic acceptance.
Existing attachments retain their identities, ownership and CKAsset path.

Verify that PH can discover the complete selected seed using the existing local
author and retained history. Missing/pruned history is a refusal, not permission
to reset the cursor or synthesize a second upload queue. Retain the verified v1
backup and conversion receipt; activation does not authorize source retirement.

## Durable remote authority

Reserve one fixed library control record, `graphevo.activation`, in the selected
private graph zone, with a dedicated `GraphEvoActivation` record type. Its bounded
versioned body contains GraphID, activation UUID, seed-manifest digest and count,
an opaque conversion/mapping commitment and phase (`seeding` or `published`).
Raw legacy identifiers, paths, native receipt contents and account credentials
are not published. Local evidence binds the opaque commitment to the exact
receipt/map and native store; it is never an application format registry.

Create/compare the record with native optimistic concurrency, following the
existing ledger's use of
[`ifServerRecordUnchanged`](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged).
Prove first-create collision behavior in deterministic adapter tests and on a
fresh physical zone before accepting the implementation. An untagged overwrite,
last-edit policy, KVS flag or diagnostic MF03 ledger must never elect authority.
If first-create exclusion cannot be demonstrated, stop and revise this contract
before implementing publication. The new control record also requires explicit
CloudKit schema/deployment validation before production activation.

Before a first claim, obtain a complete bounded inventory proving that the zone
contains no application/share/foreign control records. An absent zone may be
created for this explicit request. An existing claim is inspected before deciding
emptiness. Competing compliant activators may inspect an empty zone concurrently;
only the winning exact claim permits application sends. A pre-existing ordinary
binding to the target is refused. Unexpected records block rather than being
adopted, overwritten or deleted. This protocol does not fence arbitrary old or
external writers that bypass it.

Only the exact same activation/seed commitment can resume a claim. A different
conversion or operation is a visible authority conflict, even when row counts or
application values happen to match. No timeout or device clock steals authority.
An ambiguous claim save requires a fetch and exact comparison before any upload.
Missing/deleted authority after seeding began is a blocked recovery condition;
never recreate the zone or claim automatically. Claim updates retain native
change tags and reject foreign revisions.

Keep activation controls separate from primitive decoding, PH upload, the
application inbox budget and the rotating shared diagnostic ledger. Reuse the
session's scope gate/account/stop fences; allocate no additional CKSyncEngine.
The implementation must version its durable local/session/control formats
explicitly and refuse incompatible alpha state unchanged. S04 and primitive/
asset formats need no revision solely for this control protocol.

## Seeding, publication and peers

After confirmed authority, the selected native owner sends through existing
PH pending generations, immutable attempts, T01 receipts and T04 assets. Reuse
partial-success and ambiguous-send recovery; never replay consumer bodies or
acknowledge work from a local save alone. All target send paths, including manual
and foreground operations, must check activation admission; a raw bind cannot
bypass it. Consumer mutations and initial sharing remain held during seeding.

Publication requires acknowledged seed work, no remaining initial upload attempt,
and an independent complete bounded server inventory matching the immutable
manifest, including topology and attachment bytes/digests. Use supported record/
asset access, without inferring remote content from native metadata or a query
count. Enumerate the complete zone through supported zone-change access from a
fresh verification cursor, without rewinding engine serialization or consuming
its inbox as a verification shortcut. Unexpected/missing data keeps the phase
`seeding`. Check cancellation and
account/zone generations throughout. Persist recoverable verification evidence
before conditionally advancing the authority record to `published`.

`published` certifies that one immutable seed was observed on the server at the
verification boundary. It never certifies future convergence or all devices.
After confirmed publication the owner releases only its activation holds and
ordinary edits/scheduling can resume. An ambiguous publication response is
resolved by fetching the exact authority before releasing those holds.

A peer uses an explicit empty-replica recovery path, verifies the published
authority on the trusted route and imports via the existing inbox/import author.
A locally converted nonempty store is refused as a peer, even if its GraphID
matches. Initial consumer access and uploads stay gated until a complete coherent
graph passes normal integrity/admission. Imports must produce no outgoing work.
After publication, ordinary owner edits may already exist: peers recover current
cloud state and must not require it to equal the historical seed digest. They
retain the published authority identity, then follow ordinary transport semantics.
Peer row UUIDs come from cloud records; the legacy lookup map stays protected on
the authoritative source and is not required for ordinary peer operation.

## Recovery and result meaning

Persist intent before remote operations. Durable state distinguishes local
preparation, uncertain/confirmed claim, seeding and uncertain/confirmed publication.
Recovery validates the native receipt/store/PH epoch, immutable manifest and exact
account/route before resuming. Persisted routing has no sandbox paths; the host
supplies current URLs on restart. No lost response authorizes a second authority.

Restart restores activation admission before exposing writers, transport or
sharing. A failed detach retains native claims. Cancellation drains admitted
native work; acknowledged remote effects remain committed and visible as pending
recovery. Offline/authentication/quota failures remain resumable or blocked with
their real cause. Never clear claim/intents on a generic network failure.

Return durable activation identity/phase separately from current local handle
availability, transport errors and cleanup warnings. A successful local conversion
is still valid when activation fails. An abandoned partial seed retains source,
backup and remote authority for explicit recovery; automatic deletion, authority
transfer and takeover from a restored backup are later work.

## Acceptance and delivery

The implementation is one focused increment from/to `codex/graphevo-2`, after
review of this contract. Required deterministic coverage includes competing
conversions, same-claim resume, every durable/network boundary, partial uploads,
ambiguous claim/publication saves, stale generations, account changes, raw-bind
bypass, all manual/automatic send paths, oversized Data, history gaps, foreign
zones/records, deleted authority and native-detach quarantine. Prove that restart
cannot expose the held writer and that unrelated graphs continue progressing.

Use public synthetic fixtures for a physical protocol: two competing converted
copies, exactly one selected authority, process restart during bounded seeding,
server verification, genuinely empty peer recovery with exact identities,
topology/values/assets and no import-upload feedback, then ordinary later edits.
Retain writer owners until independent observation. No reset, copied fresh replica
or consumed-mutation replay. Private support archives/logs remain external to
Git/CI/device/cloud; historical/production source acceptance is separate.

For this documentation-only proposal, check links and `git diff --check`; do not
repeat unchanged suites or request remote CI. Implementation requires affected
local checks, review/corrections, the checkpoint required by the current
[CI policy](graphevo-2-ci-checkpoints.md), then authorized merge. Broader v1
writer/completeness policies, historical sources, cross-process interruption,
capacity, public bootstrap and beta/stable acceptance remain open.
