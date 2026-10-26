# V02 — participant-created member in an existing share

A fresh, cross-account physical-device run demonstrated a supported path for
participant-created graph members. The read-write participant XR inserted an
unconnected A-004 into its **shared** Core Data store, saved, assigned it to
A's existing `CKShare` with `NSPersistentCloudKitContainer.share(_:to:)`, then
linked it to A-root and saved. The already-open owner iPad imported A4 while
retaining B2. Its A values, parent/inverse links, normalized CloudKit record
IDs and share IDs matched the participant; prior IDs were stable and the
participant had no run rows in its private store. Both sides retained exact
results for complete 180-second windows without errors.

In the same run, the participant deleted A-004 through its shared-store
context without another share call. The already-open owner returned to A3+B2;
both sides kept surviving identities, correct inverse links and unchanged
owner B through complete 180-second windows. This is positive feasibility
evidence for explicit existing-share assignment plus ordinary deletion, not a
delivery-time guarantee. The earlier relationship/save-only participant
insertion crashed and remains unresolved; its store was never replayed. An
intermediate variant that routed the unconnected object through the
participant's private store returned `NSCocoaErrorDomain:134060` and is not a
valid shared-store comparison.

The successful run was `E41BC9CA-320A-42FB-9F76-7B2E604B4267`, case
`C72ECAC9-948D-4EC1-8728-D573A3B94DEF`. Detailed stage reports, hashes,
the initial invalid variant, and the test procedure are in the Demo
[hardware result](https://github.com/bbruno84/GraphEvoDemo/blob/feature/verification-laboratory/docs/results/v02-participant-explicit-members-2026-10-26.md) and
[laboratory guide](https://github.com/bbruno84/GraphEvoDemo/blob/feature/verification-laboratory/docs/features/v02-incremental-shared-members.md).
Protected identity and invitation envelopes stay in the private evidence
archive outside Git. This run used the dedicated Development container and
synthetic fixtures; it did not touch production data.
