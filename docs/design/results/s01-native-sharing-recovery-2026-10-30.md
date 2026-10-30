# S01 public native sharing and recovery — physical result (2026-10-30)

Outcome: all **16 one-use stages** pass on owner iPadOS 27.0 and different-account
iPhone XR iOS 18.7.11. The selected public runtime supports this bounded sharing,
attachment-mutation and fresh-recovery fixture. This closes PA01's selected-model
native acceptance item for the scope below, not the broader PA03/PA05/PA08 gates.

## Provenance and protocol

PR #98 was reviewed and merged after exact-head macOS/iOS CI
`41044628813` passed. Runtime source is integration commit
`16be35371470e114602b22048fdcc7eabd87eee7`, containing reviewed head `77d071a`.
The disposable signed Debug host was built with Xcode 27.1. Its actual entitlement
and Info.plist checks select only the authorized Development test container
`iCloud.com.valerioburiani.GraphCKDemo`; no Production deployment occurs.
Executable/source hashes and complete raw evidence remain outside Git.

The [S01 host](../../../Experiments/S01NativeProbe/README.md) consumes public
GraphDatabase/GraphStore APIs with explicit `.nativeIdentity`, without raw data
contexts or testable access. Each stage has a new report ticket and an acknowledged
launch receipt bound to the actual CoreDevice process and active scene. All
16 case reports pass; no seed, assignment or mutation is replayed. Prior
fixtures/container contents are retained; all current case paths use a new run.
The original configured demo's project and Info.plist hashes remain unchanged.

The owner creates and invites in the same retained seed process. Subsequent
writers remain open until the other account independently observes their data.
Neither local save, setup, mapping nor process termination is used as an export
barrier. Fresh participant directories are allocated only if absent and receive
no copied SQLite, native sidecar or operation ledger.

## Observed outcomes

| Check | Observation |
|---|---|
| Setup and sharing | Owner A has an owner Entity and 512-byte/10-MiB attachments; B has its own owner/control file. Both non-nil native boundaries are distinct. Only the pinned participant joins A. |
| Initial participant recovery | XR verifies exact IDs/ownership/metadata, complete bytes, SHA-256, mappings/full native integrity and B absence; large-file export is byte-exact. |
| First empty replica | New private/shared pair under `recover-initial-replica/` recovers the original A through the already accepted invitation. Its independently collected export is exactly 10 MiB of byte 173. |
| Participant insertion | A new 512-byte attachment is assigned to existing A; the owner independently observes its same ID/content and unchanged B. |
| Replacement | XR replaces the large file with a new revision/filename while preserving identity. The owner independently recovers the replacement and retains B. |
| Second empty replica | A separate pair under `recover-replacement-replica/` recovers the participant addition and replacement state. Its independently collected export is exactly 10 MiB of byte 91. |
| Deletion | XR deletes only the large attachment; the owner observes that deletion with other A files and B intact. |
| Owner cascade and final reopen | Owner deletion removes its remaining owned files. XR independently observes those IDs disappear and B remains absent. Final owner openings retain B's exact control file and both distinct, non-nil boundaries with no pending/unexpected mappings. |
| Actual persisted model | Public Core Data metadata inspection of disposable copies confirms `GraphEvo.v2.schema.1` and twelve entity hashes on all **eight** native SQLite resources: owner pair, original peer pair and both fresh pairs. |

Export checks compare complete file contents off-device, not only size or a
metadata digest. Native integrity/read checks retain the library's full
ownership/identity/format validation; no budget or error policy is weakened.
The fixture exercises application Entities/attachments and hidden membership
controls. It is not new exhaustive application Relationship/Action acceptance.

## Evidence protection and limits

After final independent observations, only the acknowledged probe processes
were terminated and their absence checked. Complete owner/peer case directories,
including fresh pairs and external content, were preserved. Model metadata was
read using the public API on separate disposable copies, protecting the original
copied artifacts. Process disappearance is not a clean native-detach certificate.
Identity/invitation transports, raw native logs, stores and personal signing
configuration remain private. Cloud records/shares and local fixtures remain;
future fresh paths must not assume an empty cloud account.

There were no failed device stages or launch continuations in this run. During
host preparation the entitlement reader initially received DER instead of XML;
explicit XML output fixed inspection before any Graph stage. That tooling issue
does not represent a signing or CloudKit failure.

The [local adoption result](s01-runtime-adoption-2026-10-30.md) separately records
530 package tests and the volatile-SHM byte-oracle correction. This physical
fixture is not a production size/performance envelope, streaming guarantee,
global sync certificate, arbitrary interruption/concurrent-writer test or account
switch/revocation policy. Consumer-format admission, mixed/future data migration
and mandatory complete v1 conversion remain open. The optional native version
column's existence is not an implemented application compatibility gate.
