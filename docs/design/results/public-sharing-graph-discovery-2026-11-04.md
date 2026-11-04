# Public sharing: GraphID discovery through Apple's invitation flow

Date: 2026-11-04. Documentation/source investigation, not implementation or
physical CloudKit acceptance. Source baseline: `a1097ff1`, H02 draft `8fe16a92`.

## Finding

A separate GraphEvo invitation file is not inherently required. Apple's normal
share URL/metadata, native acceptance and shared-database reads provide a route
to discover GraphID. The current T07 implementation requires GraphID before
acceptance; that is our current protocol ordering, not an Apple restriction.

For a reliable bounded lookup covering empty graphs, the recommended protocol
addition is one small, versioned identification record at a fixed record name
in each shared graph's zone. This record does not yet exist in shipping code.
It is a cloud protocol addition requiring review, not a native Core Data schema
change or permission to reinterpret old zones.

## Apple evidence

- [CKFetchShareMetadataOperation](https://developer.apple.com/documentation/cloudkit/ckfetchsharemetadataoperation)
  supplies sharing/participation metadata; fetching a root application record is
  not applicable to zone-wide sharing because there is no nominated root.
- [Apple's sharing walkthrough](https://developer.apple.com/videos/play/tech-talks/10874/)
  demonstrates URL-to-metadata acceptance followed by reads in
  sharedCloudDatabase. Its zone-sharing section retains the same acceptance and
  fetch mechanism. A GraphEvo identity does not have to be known to call Apple's
  acceptance API.
- [recordZoneChanges](https://developer.apple.com/documentation/cloudkit/ckdatabase/recordzonechanges%28inzonewith%3Asince%3Adesiredkeys%3Aresultslimit%3A%29)
  supports selecting fields and bounded pages. Thus discovery can omit payload
  and asset fields, although scanning still has costs and can find no live node.
- [record(for:)](https://developer.apple.com/documentation/cloudkit/ckdatabase/record%28for%3A%29)
  permits fetching a known record ID directly. Combining a constant record name
  with the exact accepted share's zone ID avoids discovering application node IDs.

The fixed-record design is an inference from these APIs, not an Apple-provided
GraphEvo identity service. A bare URL does not itself contain GraphID. Native
metadata provides the exact share/zone to address; GraphID is learned from a
subsequent shared record read.

## Existing source evidence

`Sources/GraphEvoStore/GraphCloudNodeCodec.swift` encodes a `graphID` String field
on each GraphEvoNode, outside the serialized payload. A selective zone read can
therefore discover candidate IDs without decoding properties or attachments.
It cannot guarantee a result for empty graphs or graphs whose nodes were deleted;
the first observed node also does not certify the entire zone's consistency.

`GraphCloudActivation.swift` already defines fixed record `graphevo.activation`,
type GraphEvoActivation, containing GraphID. That is an MF10 authority record,
not a universal graph descriptor. `GraphCloudActivationService.swift` currently
fetches it through a private binding that already contains GraphID. Ordinary new
graphs need not use MF10 and can be empty. Reusing that record as a mandatory
generic descriptor would conflate authority/cutover with identity discovery.

`GraphCloudSharing.swift` validates an existing capability and verifies the
recipient, share, zone and owner before native acceptance. The manager prepares
the graph/route before this step. Native onboarding needs to split acceptance
and identity discovery from local graph creation while preserving these checks.

## Recommended flow for H02 discussion

1. Owner publishes/validates the small identity record before exposing the share
   through an admitted Apple sharing presentation. Ambiguous creation and cleanup
   retain T07's durable intent; no additional engine or independent share writer.
2. Participant receives native metadata or resolves the standard URL. Verify the
   configured container, actual zone-wide share, current participation/permission
   and account epoch. Let CloudKit identify the intended participant; no advance
   exchange of account record names is inherently required by the native flow.
3. Persist a bounded joining intent keyed by account/container/exact share-zone
   before acceptance, even though GraphID and the local file are not known yet.
   Retry inspects native acceptance and resumes the same intent.
4. After acceptance, fetch the exact identity record from the shared database.
   Validate record type/name, version, zone and GraphID. Missing/offline metadata
   leaves a resumable join; never invent an ID or erase/recreate a store.
5. Return detached identity information so the host can select its explicit local
   SQLite URL. Claim GraphID/resource ownership and establish the immutable route
   through the existing context. Ordinary imports must match that identity.
6. Existing T07/T08 permission, import, observation and leave/revocation paths
   continue. Membership acceptance and record discovery do not certify data import
   completion. Account loss remains isolation, not evidence authorizing purge.

The identification record is routing metadata, not an authorization credential.
Shared writers may modify application records; do not assume this descriptor is
owner-only writable without evidence. Pin established bindings, refuse mismatches,
and never use an edited descriptor to redirect an existing replica or authorize
file deletion. Missing/conflicting descriptors require recovery, not silent rebind.
The control record must be explicitly recognized by incoming classification,
outgoing conflict rules and bounded queue accounting; it must not reach the
GraphEvoNode decoder as an application record. Preserve MF10 authority semantics.

## Remaining verification before adopting the protocol

The feasibility conclusion is documented, not physically demonstrated. A bounded
two-account probe should verify native UI/callback metadata, acceptance, exact
descriptor fetch for an empty graph, read-only participation, delayed/missing
descriptor retry, interruption after acceptance before local creation, account
change and conflicting descriptor handling. Keep any direct reads within the
existing session scope admission and leave CKSyncEngine's import checkpoint
untouched; discovery is not a substitute fetch cursor or a second engine.

Review persisted pre-GraphID join intent/versioning, old-alpha-zone compatibility,
participant edits/deletion and native sharing UI reconciliation before selecting
the exact public APIs. No automatic migration, shipping source changes or beta
gate closure follows from this research.
