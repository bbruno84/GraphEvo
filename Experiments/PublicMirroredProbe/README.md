# Public native mirrored schema consumer

The functional private/A6 consumers use only `import GraphEvo`: no package APIs,
`@testable` imports, raw contexts or direct Core Data/CloudKit manipulation.
The separate diagnostic controller uses documented read-only CKShare APIs and
is explicitly excluded from public-product consumer evidence. It
provides a private-only typed consumer and the A6 private/shared attachment flow
through the new public schema overloads. It links the local checkout while leaving
the original configured demo untouched. Its disposable app delegate starts each
CLI request exactly once independently of scene visibility; scene construction
only presents the retained controller. It never selects the v1 demo on cold launch.

```sh
python3 Experiments/PublicMirroredProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoPublicMirrored
xcodebuild build -project /tmp/GraphEvoPublicMirrored/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoPublicMirroredBuild -allowProvisioningUpdates
```

Use the authorized Development container and controlled compatible cloud state.
No cloud reset or alpha conversion is part of these consumers. The native public
factory now requires Core Data model version `GraphEvo.nativeIdentity.alpha.2`;
existing unversioned alpha/prototype paths are refused before native loading even
when entity hashes match. Start incompatible alpha fixtures on new paths, keeping
previous reports/intent; do not stamp old metadata to bypass refusal.

## Private-only consumer

Launch once with `--native-public <new-run-UUID>`. Store and `private.txt` report
are under `Library/Application Support/GraphEvoLaboratory/NativePublicPrivate/<UUID>/`.
It checks one completed native setup, typed create/insert/query/observed initial
state, public full integrity, owner-boundary preparation and all member mappings,
then existing-local-store reopen and stable application identity/value. The
reopened owner remains alive. This does not establish independent replica recovery
or that local close/mapping is an export-completion barrier.

## Private/shared public consumer

The generated A6 source retains plain `import GraphEvo` and calls:

```swift
let database = try await GraphDatabase.openMirrored(
    privateStoreAt: privateURL, sharedStoreAt: sharedURL,
    containerIdentifier: containerIdentifier, schema: .nativeIdentity)
let count = try await database.validateIntegrity(of: graphID)
```

Follow [A6's ordered one-use stages](../A6NativeProbe/README.md) on the iPad owner
and different-account XR with a separate new run UUID. Paths remain under
`GraphEvoLaboratory/NativeIdentityFiles/<UUID>/`; protect transports and never mix
runs. Add public setup/seed progress checkpoints to distinguish native setup,
local file insertion and owner-boundary preparation. Preserve first failures,
stop on a reserved-stage failure and never replay a seed/native assignment.
A new incompatible alpha implementation requires a new fixture, not reuse of a
failed older run.

The [Swift 6 Release consumer](../../IntegrationTests/PackageConsumer/README.md)
separately compiles both mirrored overloads and exercises early invalid-URL
refusal without credentials. That check is not successful CloudKit opening.
Device hosts use the configured demo's language mode; their public module
boundary is complemented by the independent Swift 6 package consumer.

## Explicit continuation and diagnostics

The public A6 host supports separate `accept-resume` / `accept-after-visibility`
tickets for the existing invitation. acceptInvitation checks current native
participant status and does not reaccept an already accepted share. An explicit
`invite-resume` ticket re-persists only the original recipient on the existing
prepared boundary and requires canonical invitation equality, writing a separate
resumed transport. These tickets are operator decisions after retained failure
evidence, not an automatic retry loop or permission to replay native assignment.

`--native-diagnose <A6-run-UUID> owner|peer|owner-visibility|peer-visibility` uses
separate one-use reports. It checks only protected invitation binding, server
share metadata/participant summaries and the public boundary's server CKShare.
The bounded peer visibility mode repeats reads only. No signed URL/account IDs,
participant identities or payloads reach logs. It invokes no invitation,
acceptance, native assignment or direct record mutation. Owner opening can still
start normal native mirroring; this is not a CloudKit pause.

See the [retained adoption result](../../docs/design/results/native-public-mirrored-schema-2026-10-29.md)
for private success, paired failures/continuation and actual remaining scope.

`observe-replacement-resumed` is a distinct read-only ticket for existing saved
replacement data after a host launch without an on-device stage report. No
replacement is replayed. The CLI host's start guard prevents app-delegate and
viewDidLoad callbacks from starting the same request twice.

The retained device run also used `observe-deletion-resumed` as a separate
read-only ticket. When ordinary launches yielded no report, the final stages
used CoreDevice start-stopped launch followed by LLDB with an explicit local
iOS symbol target and actual CoreDevice UUID, then attach/detach before app work.
No debugger expression modified application/native state. Do not infer a Core
Data hang from a missing UI/report; retain the launcher evidence separately.
