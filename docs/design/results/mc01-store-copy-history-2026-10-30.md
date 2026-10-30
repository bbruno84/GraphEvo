# MC01 — closed working-store copy and native-history publication

Date: 2026-10-30. Result: **bounded whole-store feasibility demonstrated**.
Experiment-only branch; [PR #104](https://github.com/bbruno84/GraphEvo/pull/104)
was closed without merge. The integration branch remains unchanged. This result
informs a future separately developed solution; it does not select a copy-based
manager architecture, per-graph publication contract or public activation API.

## Question and procedure

Can the consumer edit a copied store using normal Graph APIs, return it complete,
and let native mirroring export those edits after replacing/reopening the original,
without a post-open application save? See the reproducible
[MC01 procedure](../../../Experiments/StoreCopyProbe/README.md).

Starting integration revision: `b95ab1f` (#103). The measured disposable Debug host
contains the experiment's uncommitted library/host sources; their SHA-256 values:

- Host: `aa4d6aff40b08d2407c24f98448a959536c14dc590f1a0b792a268d295a3ec6e`.
- Library helper: `58e76f0a1c3418666e64a26f6fd2611084d4039711b4fe9184a09309d19ef214`.

After the measured device run, the helper explicitly propagates history-reader
detachment failures instead of suppressing them; local MC01 checks are rerun.
Successful copy/history behavior is unchanged. The hashes above identify the
actual measured device snapshot, not a claim to exercise teardown failures.

Protected external evidence retains executable/debug-library hashes, signed
entitlement checks, source snapshots, run-bound transports, launch receipts,
PID/ticket-bound reports, original backup, working/live stores and fresh replicas.
Do not commit those artifacts or account/invitation identifiers.

Environment: Xcode 27.1 (27A9275), Swift 6.4; physical iPad 10th generation
(iPad13,18), iPadOS 27.0 (24A437), owner account; physical iPhone XR (iPhone11,8),
iOS 18.7.11 (22H384), different iCloud account. Signed host uses the authorized
Development test container. Both devices were unlocked. The configured demo was
not edited. Existing cloud data was not reset; assertions select new run-bound
fixture IDs and do not assume the account/container is empty.

## Matrix and observations

| Case | Outcome | Actual evidence |
|---|---|---|
| Local Core Data copy | Pass | Store UUID, prior history counts and starting-token usability retained |
| Local closed-directory copy | Pass | Same checks, complete file contents and later publication retained |
| Local edit/publish/reopen | Pass | Insert/update/delete history, removed property, new node, changed edge, preserved action, transient create/delete, owner/file cascade, 2/3-MiB bytes and control B |
| Stale-original counterexample | Unsafe as expected | A later edit on the original control graph is overwritten by complete store replacement; no native graph merge/stale check is supplied |
| Existing destination/wrong model | Refused | Destination marker retained and no incompatible destination created |
| iPad prepare + XR identity | Pass | Separate acknowledged processes and protected recipient transport |
| iPad seed + XR baseline | Pass | A's nodes/edge/action/files and native mappings independently observed before owner replacement; B absent from participant |
| iPad local-copy publication | Pass | All graph/database leases closed; whole-directory backup retained; Core Data work copy edited locally without CloudKit; changed history retained on publication |
| Reopened owner | Pass | No application save after mirrored reopen; local migrated values/files and mappings valid; A share boundary unchanged, B boundary distinct/control unchanged |
| Existing XR replica | Pass | Independently observed additions, property removal, endpoint update, owner/file deletion and exact replacement bytes |
| Fresh XR pair | Pass | Absent private/shared directory, original accepted invitation, no copied native store; complete migrated fixture/mappings independently recovered |
| Final owner | Pass | Migrated fixture/control verified again after fresh peer recovery |
| Copied-resource metadata | Pass | Seven actual resources carry S02; owner/work/backup keep the same UUID; all four peer store UUIDs are independent |

The device protocol completed all **eight stages** with reports bound to actual
launch PID/ticket and active scene. Mutation stages were not replayed. Writers
remained alive through independent observation; only acknowledged probe PIDs
were stopped after the final checks. The fresh replica received only invitation
and fixture transports, never a store or native sidecar.

Native metadata/history was accessed only through public Core Data APIs. There
was no private-table inspection, token transplantation, manual metadata stamp,
manual CloudKit record upload, schema reset or zone purge. No Graph diff, custom
mutation log or manager-level operation replay was used.

Large file content survived Core Data copy/publication and fresh cloud recovery.
Physical inline/external placement is not stable across these operations; this
result certifies bytes/identity/ownership, not a particular external-file layout
or a backup implementation for arbitrary providers/auxiliary ledgers.

## Retained correction and limitations

The first stale-original test used read-only opening immediately after replacing
an unmodified work copy and failed with Cocoa 256 / SQLite 8. The intended writable
activation route passes and demonstrates the overwrite. This correction is
retained, not represented as proof of read-only-first activation. Diagnose and
validate widget-before-app/readonly activation during manager lifecycle work.

The initial full local suite passes **560 tests**: 331 legacy, 140 store (three
new MC01 functions, including a two-method parameterized case), 66 runtime,
23 model. Manifest/diff checks and physical Debug host build pass. Any CI result validates only this experiment; it is not authorization to merge
the experimental implementation.

This is not proof of:

- Safe publication while any process/lease can still write the original. The
  counterexample proves complete-store replacement can lose unrelated edits.
- Per-graph physical replacement when several graphs share one store, or atomic
  replacement of a private/shared resource pair.
- Participant-side writable offline copies or permission-safe native assignment
  from a copied shared store. The tested writer is the owner-private resource.
- No conflicting remote writers, a complete import, global cloud quiescence,
  deterministic same-record conflict resolution, or ongoing import processing.
- Process kill/power loss during publication, automatic rollback, complete backup
  of app-owned ledgers/providers, readonly-first startup or production rollout.
- Full v1 native/data/codec conversion or all S02 sharing/account/conflict/scale
  gates. This closes only S02 owner sharing/file/fresh-recovery feasibility.

## Direction

Before implementation, settle the distinction between logical graph migration
and whole-store replacement. Current GraphDatabase resources can contain several
logical GraphStore graphs. The demonstrated copy route requires control of the
whole resource, including unrelated graphs; it is not independent per-graph
publication. Preserve this as one technically feasible option, not an accepted
production architecture.

Once the scope is agreed, develop the solution separately from the experiment.
Graph owns infrastructure, not application semantic quality. Source protection,
resource/account binding, stale-source refusal, durable recovery, widget readiness,
remote conflicts and mandatory v1 conversion remain open. Do not create an
experiment-parent integration stack or merge this laboratory as production code.

References: Apple's [persistent history](https://developer.apple.com/documentation/coredata/persistent-history),
[store replacement](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/replacepersistentstore(at:destinationoptions:withpersistentstorefrom:sourceoptions:type:)),
[Core Data sharing/history](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
and [TN3163](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer).
These describe public mechanisms; the bounded result above is experimental evidence,
not an Apple guarantee for an arbitrary copied-store migration workflow.
