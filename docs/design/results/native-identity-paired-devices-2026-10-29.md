# Native identity paired device acceptance — 2026-10-29

## Scope and core result

The authorized owner iPad (iPadOS 27.0) and different-account iPhone XR
(iOS 18.7.10) exercised the internal
fresh native identity layout through one NSPersistentCloudKitContainer with
explicit private/shared stores on each device. The maintainer had reset the
approved Development container. New local fixtures were used; no library open
converted, repaired or erased old data. Public mirrored defaults remain unchanged.

The source baseline was 164324d with the native paired A5 host. An additional
host-only revision added distinct explicit recovery/reinvitation tickets after
the observations below; library persistence/runtime code did not change. The
updated host compiled successfully for generic iOS and preserved existing stores
and journals when installed. Protected transport files, stores, raw reports and
logs remain outside the repository. No account identifiers, invitation URLs,
share/zone IDs or application payloads are recorded here.

| Check | Observed result |
|---|---|
| Native setup | Successful native setup events for both resources on both devices |
| Owner seed | A5/B5, distinct owner-only native boundaries and full native storage integrity |
| Independent participant import | XR recovered exact A5 identities/endpoints/values, shared participant scope, B absent; 35 owned native rows all mapped to A |
| Participant additions | Entity, Relationship and Action assigned once; XR and independent owner recovered A8; owner B5 unchanged; 51 mapped rows |
| New details | Participant added properties, tag and group; owner recovered exact values and native mappings; A8/B5 retained; 55 mapped rows |
| Read-only | XR observed accepted read-only metadata and the library rejected a patch before save |
| Restored read/write | XR edited an existing detail; owner independently recovered it with unchanged B |
| Interruption | Debug pause reached after native assignment; pending patch intent remained publicly visible before process termination |
| Explicit recovery | First attempt failed with Cocoa merge error 133020. Original ledger survived; a later explicit recovery finalized that same intent without another native share call. XR and owner recovered the value, A8/B5 and 56 mapped rows |
| Revocation | A disappeared on XR while its pinned private control survived |
| Reinvitation | New invitation accepted; XR independently recovered complete A8, B absent and correct mappings |
| Voluntary leave | Only shared A disappeared from XR; private control survived. Independent owner retained A8/B5, exact details and distinct complete native boundaries |

Full native storage validation ran on owner seed and A/B recovery. Point hits,
setup, mapping, full local integrity and independent peer observation are separate
evidence. This is one controlled synthetic run, not a synchronization-completion,
global uniqueness, server enforcement, quota or arbitrary concurrency guarantee.

## First recovery conflict is retained evidence

The first `recover-patch` returned NSCocoaErrorDomain 133020, identified by the
installed Core Data SDK as NSManagedObjectMergeError. It did not produce a pass.
The originating local operation ledger still contained one intent and was copied
to protected external diagnostic storage before any further recovery attempt.
The error alone does not identify which competing writer or native activity
caused the merge conflict; no native bookkeeping internals were inspected.

The host added a distinct `recover-after-conflict` ticket and invoked the existing
public recovery API against the retained plan. It did not rerun `patchShared`,
recreate staging IDs, discard intent, change merge policy, or invoke native share
assignment. Recovery required the recorded one-object patch, an empty ledger
at completion, exact recovered value and independent owner observation. Both
sides retained all application identities and graph boundaries.

No automatic retry or conflict suppression was added to the library. Broader
conflict/crash combinations, deterministic failure injection and application
recovery guidance remain PA04 follow-ups. The first error and subsequent success
must both remain in future acceptance summaries.

## Host launch failures

Two `devicectl --terminate-existing` launches returned CoreDevice error 10004
before the target stage created its report. Directory inspection confirmed no
invite report or invitation file for the first failed launch. No mutation stage
was replayed. The distinct existing `reinvite` route performed the first actual
invitation; the original failed launch receipt was retained. The second failure
preceded a read-only owner observation, for which a distinct read ticket was used.

Later launches separated termination of the known demo process from foreground
launch. No crash report was found in the device crash-log listing at diagnosis.
This does not prove why the launcher failed. The observation named
`owner-after-leave` was used early to independently check additions; the actual
post-leave owner check used `owner-observe-rw-recovered`, which also checks the
exact restored details and B. `reinvite-after-revoke` was a separate host ticket
for the new invitation after confirmed revocation.

## Separate native attachment run

A fresh A6 host/fixture used the same internal native schema on new local private/
shared resources and the existing controlled Development state. It added no
CloudKit reset and did not reuse A5 file paths/transports. Its host-only native
schema selection, full integrity checks and final empty-A check compiled for
generic iOS; ordinary public attachment operations performed the mutations.

| Check | Observed result |
|---|---|
| Owner fixture | A held one owner plus 512-byte and 10-MiB files (3 records); B held one owner plus a 512-byte control (2 records), with native integrity verified |
| Independent import/export | XR recovered A only, exact metadata/bytes/checksums and all owned mappings; exported the exact original 10-MiB body |
| Participant import | New 512-byte attachment assigned to existing A share; independent owner recovered exact metadata/bytes; A count 4 |
| Replacement | Participant replaced the 10-MiB body, preserving ID and changing revision. Owner recovered exact new bytes; XR independently exported the replacement bytes |
| Participant deletion | Owner independently observed the large attachment absent with surviving files/control intact; A count 3 |
| Owner cascade | Owner deletion removed its surviving files including the participant-added attachment; XR recovered exact absences and full A integrity count 0 |
| Final control | Owner retained B's exact file metadata/bytes and both distinct non-nil native boundaries, with no pending or unexpected mappings |

Every A6 stage passed. No assignment replay or recovery conflict occurred in this
file run. Sampled memory output is retained externally but is not a new timing
campaign, production envelope or comparison with prior cost measurements. This
proves logical deletion observed by peers, not immediate remote asset garbage
collection or quota reclamation.

## Remaining scope

The controlled native-column private/shared and attachment acceptance gate is
satisfied for these fixtures. Public native mirrored selection requires its own
reviewed increment; this probe does not switch defaults, freeze the schema or
enter beta. Broader PA03/PA04 concurrency/account/crash coverage, larger file
envelopes, mandatory v1 migration and beta compatibility remain open. Initial
recovery conflict handling and the later successful explicit recovery must both
be retained when assessing readiness.

## Repository checks and parent review

After the physical runs, the complete local suite passed again: 512 tests
(322 legacy, 106 store, 61 runtime, 23 model), with manifest and diff checks.
Both generated native A5 recovery and A6 file hosts built successfully for
generic iOS and ran on the two physical peers. Earlier selected TSan coverage
remains the 13-test readiness record; it was not a new device sanitizer run.

PR #89's previously queued iOS job had been cancelled before execution. Rerunning
that job completed successfully on the unchanged reviewed 0529caa head, alongside
the successful macOS checks in run 40856799055. The prospective merge tree matched
the tested tree; #89 merged through its PR at 6a305e33c104e4b19a3e80b9e81e0c8d0ad8f54a
into the consolidation parent. No v2 integration/tag/release promotion occurred.
