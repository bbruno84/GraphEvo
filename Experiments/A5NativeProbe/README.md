# A5 native sharing probe

This host adapter runs GraphEvo's real candidate schema and public v2 APIs on the
authorized iPad owner account and XR participant account. Use only synthetic data
in the approved Development container. Never log or commit identity/invitation
transport files, native logs or stores. Read the demo's README/AGENTS first.

Prepare a new disposable demo copy; the original checkout/settings remain intact:

```sh
python3 Experiments/A5NativeProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoA5Demo
xcodebuild build -project /tmp/GraphEvoA5Demo/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoA5Build -allowProvisioningUpdates
```

Use Debug for the explicit recovery control. The copy links this library
checkout and adds a CLI `--a5 <stage> <new-run-UUID>` route. Local signing files
remain local. App installation updates the configured demo bundle while retaining
its app data. The normal stages use one private/shared native owner per process.
They do not initialize GraphProvider or run v1 migrations.

Every stage reserves its report before opening or mutating. Never replay a
reserved stage after success, failure, timeout or interrupted execution. Files
are under `Library/Application Support/GraphEvoLaboratory/A5/<run-UUID>/` in app
data. New readers/observations use distinct stage tickets rather than replaying
writes. Local native opening and setup are reported separately from recovered
graph state. Mutation stages retain their native owner after local success until
an independent peer confirms recovery. `resume-writer` reopens existing saved
files without repeating a mutation; `owner-observe-rw-recovered` is a distinct
read-only observation ticket after a timed-out original observation.
No cloud reset, account change or schema wipe belongs to this probe.

## Ordered stages and transport

1. XR `identity` writes a protected, run-bound `identity.json` and creates a
   personal private control graph. iPad `seed` creates A and B with five real
   graph nodes each, a cycle, properties/binary data, tags and groups, then
   prepares two personal native boundaries.
2. Transfer `identity.json` XR→iPad and `fixture.json` iPad→XR through protected
   app-data files and a private local transport directory. Keep their run UUIDs
   and the original device/account binding. Never substitute another recipient.
3. iPad `invite` adds only that XR recipient to A and writes protected
   `invitation.json`. Transfer it to the XR; `accept` accepts only pending native
   metadata, then waits for complete A5, shared scope/participant role, mappings
   and absence of the pinned B graph. Acceptance alone is not a pass.
4. XR `participant-add` edits an existing field and inserts Entity, Relationship
   and Action together through `insertShared`, including owned detail rows.
   Recovery of recorded intent is allowed when assignment mapping is pending;
   the native share call is never replayed. iPad `owner-observe` must independently
   recover A8, exact IDs/references and unchanged B5.
5. XR `participant-details` adds new properties, a tag and a group through
   `patchShared`. iPad `owner-observe-details` independently checks exact values
   and native zone membership. The application node count remains eight.
6. iPad `read-only`; XR `read-only-probe` waits for read-only metadata and must
   observe the library reject a real patch before save. iPad `restore-rw`; XR
   `read-write-probe` waits for read/write and edits an existing field. iPad
   `owner-observe-rw` must recover that value before revocation.
7. The optional explicit recovery control below interrupts an assigned patch
   and verifies recovery before lifecycle changes.
8. iPad `revoke`; XR `observe-revoked` requires A disappearance and preservation
   of its pinned private control. Then iPad `reinvite` persists a new invitation;
   transfer the newly written `invitation.json` and use XR `reaccept`. Finally XR
   `leave` must remove only A from the shared store and preserve the private
   control. `owner-after-leave` independently checks that owner A/B remain available. These operations affect only this run's
   graph/recipient; never pass a nil or owner-private store to purge.

The probe checks complete application ID sets/counts and representative values,
references, binary bytes, tags/groups and all selected owned native row mappings.
It does not compare every field/timestamp byte-for-byte. Zero mismatched mappings
with pending mappings is not positive evidence. It sends only the authorized
private invitation; B remains personal. Poll windows are bounded and do not
establish permanent denial, server enforcement or a latency guarantee.

## Explicit process-interruption control

Only `A5RecoveryProbeControl.swift` uses `@testable import GraphEvo` for the
Debug-only pause seam; regular stages consume public APIs. After read/write
restoration and owner recovery:

1. Start XR `interrupt-after-assignment`. It records a new patch intent, performs
   the actual native existing-share assignment and stops before graph finalization.
2. Require both `ASSIGNMENT-PAUSED` and `INTENT-VISIBLE` in its retained report.
   The latter verifies the public diagnostic remains readable with the writer
   paused. Do not call the interrupted stage passed or replay it.
3. Terminate that app process, then launch `recover-patch` against the same files.
   A `--terminate-existing` launch is the process boundary. Recovery must use the
   recorded operation, create no replacement IDs/share and empty the local ledger.
4. iPad `owner-observe-recovery` must independently recover the value and A8/B5.

The hook is absent in Release. Missing native mappings or divergent intent/data
remain pending/error states. Do not clear journals, delete staged objects, purge
zones or replay assignment as a fallback. Whole-store backup includes the local
ledger. Additional malformed/permission/crash combinations remain release gates.
