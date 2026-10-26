# V09 — shared graph and native attachments (2026-10-26)

## Question and setup

Can a disposable Core Data graph with Entity, Relationship and Action
equivalents, plus binary attachments, remain in one private share while a
different-account participant edits it? This is a direct
`NSPersistentCloudKitContainer` experiment, not a GraphEvo 2 implementation
or a v1 integration test.

GraphEvoDemo used one private and one shared SQLite store per device in the
authorized CloudKit Development container. The owner was a physical iPad
(iPadOS 27.0, build 24A437); the participant was a physical iPhone XR (iOS
18.7.10, build 22H374) with a different iCloud account. Xcode was 27.1
(27A927). The demo baseline was `8196e02`, GraphEvo dependency
`4dc0a7f9`; the V09 laboratory was uncommitted during execution. The runs
used new store paths and synthetic data. Sensitive identity and invitation
files stayed outside source control.

Each graph initially had a root, two entities, a directed relationship and an
action with two subjects and one object. A and B were given different
owner-only share zones. Only A received a private read/write invitation.
Snapshots checked every member's kind, value, links, store scope, mapped
record/share zone and full B control. Attachments used a Core Data binary
attribute with external storage permitted, filename/content type and a
SHA-256 checksum. Physical binary storage paths were not inspected.

## Observed results

| Case | Independent observation |
|---|---|
| Initial sharing | Owner recovered A5+B5 in two distinct share zones. XR accepted the invitation and recovered exactly A5 in its shared store; B was absent. |
| Small attachment | Owner saved a 512-byte A attachment. XR recovered 512 bytes, metadata, equal checksum and A's share zone. |
| Large attachment | Owner saved a 10 MiB A attachment. XR recovered 10,485,760 bytes, metadata, equal checksum and A's share zone. |
| Participant replacement | XR replaced the 10 MiB bytes and filename. Owner recovered the replacement with equal checksum and unchanged B after 222 seconds of bounded observation. |
| Participant deletion | XR deleted the large attachment. Owner recovered its absence after 109 seconds; the small attachment and B remained intact. |
| Graph addition | On a fresh second run, XR created an Entity, Relationship and Action as unconnected objects, assigned all three together to A's existing share with one public `share(_:to:)` call, then linked them. Owner recovered A8+B5 with exact links and zones. |
| Graph edit/deletion | XR edited an existing A Entity; owner recovered the value after 102 seconds. Owner then deleted the three added objects; a subsequent read-only XR reopen recovered A5, the retained edit and no B. |
| Coordinated disjoint edits | In a fresh third run, both devices reached a common future-start gate. Owner and XR changed different existing A entities. Both saved and independently recovered the exact combined state with A's share identity and B unchanged, without reported errors. |

The first owner invitation attempt failed before reserving its write because
reopened share metadata was not yet available. A read-only reopen recovered all
share metadata. The laboratory now waits for a complete previous-phase
snapshot before permitting a write.

An earlier first-run graph-add stage assigned the new Entity but failed before
assigning Relationship and Action, reporting `NSCocoaErrorDomain:134410`.
Its write ticket and partial fixture were retained and never replayed. That
result does not establish the cause of the native error. The fresh second run
with one array-based share call completed and recovered all three objects.
An initial read-only XR reopen after the final deletion failed before a
snapshot; a separate read-only reopen recovered the exact final state. These
failures remain visible rather than being counted as successful stages.
An unscheduled simultaneous-edit attempt in run two was invalid because the
participant edit reached the owner's baseline preflight first; the owner did
not reserve a write ticket. Run three used a future-start gate after both
preflights. It establishes coordinated local writes and eventual convergence,
but does not prove remote import/save overlap or settle same-object conflicts.

## Limits and design implications

- Exact bytes and SHA-256 across accounts support the candidate native
  attachment route for these two sizes and devices. They do not prove
  streaming, per-file progress, eviction, offline availability, physical
  external-file placement or a general size limit.
- One array-based assignment to an existing share worked for the three new
  participant objects. Do not infer that rapid sequential share calls are
  supported or that relation/save-only participant insertion is fixed; the
  earlier V02 crash is separate evidence.
- Cloud import latency varied substantially. Local save and CloudKit event
  callbacks were not treated as completion. A bounded negative observation
  remained inconclusive until exact data appeared.
- The fixture uses one Core Data entity with kinds and inverse relationships
  to emulate graph concepts. It does not validate a final GraphEvo 2 schema,
  cross-share links, cycles, optional missing endpoints or migration from v1.
  No production store, account setting or network configuration was changed.

Apple's [Core Data sharing guidance](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
documents existing-share assignment and the lack of cross-share relationships.
[TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
also documents error 134410 for one specific duplicate-container situation;
this run did not collect enough error context to identify that situation as its
cause.
