# A4 native GraphEvo probe

This opt-in host adapter runs actual public GraphEvo A4 APIs in a disposable copy
of the configured GraphEvoDemo application. It does not replace the older V01/V02
framework fixtures or treat their single-entity models as GraphEvo integration.
Read the demo's README/AGENTS and review its configuration before preparing a
copy. The original checkout, dirty project settings and fixture data are retained.

## Prepare and build

```sh
python3 Experiments/A4NativeProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoA4Demo
xcodebuild build -project /tmp/GraphEvoA4Demo/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoA4Build -allowProvisioningUpdates
```

The copy points its package reference to the checkout containing this script and
adds a `--a4` launch route. Existing ignored local signing/entitlement settings
are copied for the build; never commit that copy or those settings. Use the
already authorized synthetic Development container. This script does not reset
CloudKit, delete stores, change accounts or send invitations. Install the built
app through Xcode/devicectl. An app update with the configured demo bundle ID
preserves its app-data container, including earlier laboratory evidence.

## Stages

Pass `--a4 <stage> <new-run-UUID>` when launching the demo. Every stage reserves
its own report path before opening or writing; never replay a reserved stage,
including after a failure or interrupted process. The directory is
`Library/Application Support/GraphEvoLaboratory/A4/<UUID>/` in app data.

1. Owner `seed` creates one writer resource, two logical graphs and five
   application objects per graph: two entities, a directed cycle and an action.
   Entity properties include binary data, tags and groups. It prepares two
   owner-only native shares and verifies distinct zones for every owned row.
2. After seed succeeds, transfer only `case.json` to the same path on a second
   **same-account** device. Do not transfer SQLite, native metadata or tokens.
   Run `read-initial` there; it creates a new independent replica. Wait for its
   final result before mutation if claiming an independent initial baseline.
3. Owner `mutate` reopens the writer and inserts a disconnected entity, an empty
   relationship and an empty action, then edits an existing entity. It uses
   ordinary typed transactions without another share call. It checks A=8/B=5
   and all owned native record mappings.
4. Second-device `read-added` creates another fresh resource and checks exact
   application ID sets/counts, edited value, empty endpoints, representative B
   values/structure/details, and distinct native zones with no pending/mismatched
   mappings. Imports and mappings are polled separately with a bounded window.
5. Owner `delete` reopens the original writer and deletes the three added
   members. Second-device `read-deleted` uses another fresh resource to check
   A=5/B=5, absence of those extra IDs, the retained edit and complete mappings.

6. Owner `reprepare`, after deletion, reuses both existing native shares and
   compares returned share/zone values to their immediate pre-call mappings.

A same-device fresh reader is a useful control but not independent-device
evidence. An XR signed into another account is appropriate for A5 invitation and
shared-store tests, not positive personal-private replica recovery. Do not send
an invitation or infer permanent denial from a bounded negative read here.

The text report records counts and stages; raw console logs may contain native
framework information and remain outside Git. `case.json` contains only synthetic
fixture IDs. The probe does not pin an identity-sensitive account envelope or
certify zone/share identity continuity across stages; compare returned native
boundary values separately when testing that contract. It is not a production
migration, live-import observation test, zone-quota test, crash/retry certification
or complete byte-for-byte fixture comparison. A pending/mismatched mapping fails
the positive boundary check. Local readiness alone never passes a replica stage.
