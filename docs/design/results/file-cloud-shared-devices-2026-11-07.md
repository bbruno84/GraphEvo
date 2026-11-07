# File sharing checkpoint on physical iPad and iPhone XR

Date: 2026-11-07, Europe/Rome. Library source: `12dee263` (PR #190).

A disposable signed Release host used a physical iPad (10th generation,
iOS 27.0) and iPhone XR (iOS 18.7.11), with different CloudKit accounts in
the configured Development container. The laboratory used one new private
owner zone, a pinned private participant invitation and independent S05
SQLite stores. Account identifiers, invitation capabilities, generated stores
and raw device evidence remain outside Git.

## Cross-account sequence

1. The owner imported a 25 MiB File with a document entity, a relationship
   to the File, a tag and a group. Native sends published the records and
   CKAsset. Public sharing preparation published the format 2 descriptor;
   the internal explicit-invitation transport invited the verified XR account.
2. The XR accepted the URL through the public connection, discovered the
   graph identity and used `openReplica(for:at:)` to create a genuinely empty
   shared replica. Fetch and application recovered the exact File ID, fixed
   metadata, SHA-256, relationship, tag and group.
3. The XR replaced the content with a different 25 MiB revision, reclaimed
   its retired revision and sent the replacement through shared CloudKit.
4. After explicit graph/connection closure and process restart, the iPad
   recovered the participant replacement with the exact metadata and digest.
   It replaced the content again and completed its private send.
5. After explicit graph/connection closure and restart, the XR resumed its
   persisted invitation and recovered the owner's new revision exactly.
6. The owner changed the accepted participant to read-only using the public
   permission API. The XR refreshed its real native access after restart;
   File replacement failed with `permissionDenied`, preserving the committed
   metadata, bytes and graph classifications.
7. The owner deleted the File. The read-only XR received the deletion;
   the File was no longer exposed through its local graph.

All stages passed. Writers remained alive through independent peer
observation; graceful closure was acknowledged before planned restarts.
Native send/fetch/application calls supplied completion barriers. This is
not a timing claim about automatic or background delivery. It does not
certify production deployment, account-switch behavior or 50 GB device
capacity.

## Forced sender termination

A separate continuation imported a 128 MiB File and froze a File-only
outgoing attempt before sending. Automatic scheduling was stopped in the
laboratory so the manual native send supplied the fault boundary.

An external-only fault in the native CKAsset provider recorded that the
retained asset had been verified and prepared, then scheduled SIGKILL
200 ms later. The fault marker and absence of the acknowledged process
PID were both verified. This fault is absent from the library branch.
The exact network/upload phase at termination was not measured.

Reopening preserved the exact frozen attempt and verified the permanent
128 MiB content. The first resume stage then failed at its send barrier;
the initial harness retained only a generic failure and did not preserve
the underlying send code. Its cause therefore remains unclassified.

A diagnostic continuation reopened the same store and again compared the
exact retained attempt before sending. It completed with two successful
records, no record failures, no transport error and no pending retry.
The read-only XR then fetched and applied that revision, verifying the
128 MiB byte count, SHA-256, fixed metadata, relationship, tag and group.
Both live graph/connection owners acknowledged graceful closure afterward.

The final peer report retained a fixed progress label saying 25 MiB; the
comparison used the transferred `GraphFile` fixture with byte count
134,217,728. The independent size assertion is retained with the raw evidence.

This proves retained-attempt recovery and eventual cross-account delivery
after a physical process termination at the native provider boundary.
It does not establish deterministic success on the first immediate resume
or a measured midstream network interruption. Further fault trials must
retain native error codes and retry advice from their first attempt.

## Follow-up: classified refusal and automatic continuation

A new run repeated account verification, seeding, the 128 MiB frozen
attempt and provider-boundary SIGKILL. Its first manual resume again
verified the exact attempt and permanent content, then retained a native
send failure: `CKErrorDomain`, code 6 (`serviceUnavailable`), failed-record
code 6 and `retryAfter = 3`. No permanent/structural rejection was reported.
This classifies the reproduced failure; the lost native code from the
original historical run cannot be reconstructed retroactively.

A distinct continuation reopened the same failed attempt with automatic
scheduling initially disabled for the equality check, then enabled the
existing production scheduler. It made no manual send calls or resets.
The scheduler completed and reached idle with no pending work. An empty
XR replica accepted the private invitation and independently verified the
exact 128 MiB File, digest, metadata, relationship and classifications.
The peer then exercised its existing replacement stage. Both owners
acknowledged graceful closure after peer observation.

The automatic trace sampled running and settled idle. It did not sample a
waiting-retry phase in this continuation, so it is not evidence of a timed
physical backoff interval. The captured preceding refusal and its native
advice are retained separately. Controlled virtual-clock tests verify
that the existing retry classifier respects that error family and advice.
Apple documents delayed retry and native advice for these transient
failures: [CloudKit retry advice](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds).

The audit also exposed a separate native provider path that wrapped a
zone-save failure in a custom error, losing its CKError code and advice.
A new regression failed against the previous implementation. The fix
retains the original CKError; the test verifies service-unavailable,
rate-limit and zone-busy retry delays, no explicit-hint bypass, successful
later settlement, and permanent permission refusal. This is not claimed
as the proven cause of the original physical failure.

The narrow provider fix passed 98 affected macOS tests and 26 iOS simulator
tests. Physical fault runs used the preceding library source with external
laboratory instrumentation. No new retry layer, queue/document format or
public API was added. The original first-run failure remains historical
evidence; the fresh repeat supplies the classified error and automatic
recovery proof.
