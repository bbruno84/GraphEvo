# GraphEvo 2 — containing app and extension access

Status: first protective increment, not a complete iOS app/widget certification.
The maintainer explicitly rejects forcing unsupported Apple configurations and
asks for safeguards where possible. Read with PA02/O03 and the A8 contract.

## Apple boundary and selected first increment

Apple's [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
warns that app and extension must not both synchronize the same store using
independent NSPersistentCloudKitContainer instances, and suggests making the
containing app responsible for synchronization. This does not prohibit a local
Core Data reader. Apple's [extension guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
requires coordinated shared-container access and identifies Core Data as an
available mechanism.

The selected v2 policy conservatively rejects all extension mirrored openings,
including an isolated extension-owned mirrored file. This is a library support
policy for this alpha, not an Apple ban on every use of CloudKit in extensions.
The v2 runtime refuses mirrored configuration in an app extension before native
model construction, gateway acquisition, store creation or container loading.
It classifies the actual Bundle.main using NSExtension metadata or an .appex
bundle suffix. Both explicit mirrored overloads pass through this boundary;
the public error is GraphStoreError.synchronizationUnavailableInExtension.
Tests inject the role only through the package-internal lifecycle test hooks.

This is an extension-specific safeguard, not an operating-system security
boundary, global process registry, detector of another application's cloud
owner, or change to v1 behavior. Existing local writable openings are not a
certified concurrent-extension-writer contract. Third-party/native/old writers
that bypass this facade are not coordinated by this check. Interactive widget
writes remain an explicit subsequent design and verification task.

A lifetime file lock is not used as an alternative distributed owner. Apple
[TN2408](https://developer.apple.com/library/archive/technotes/tn2408/_index.html)
describes suspension hazards for coordinated access and POSIX locks. This
increment neither blocks waiting for a suspended app nor tries to take over a
cloud synchronizer. It leaves existing local ownership, final-detach retention
and lease behavior unchanged.

## Explicit local read-only opening

```swift
let database = try await GraphDatabase.openReadOnly(
    privateStoreAt: privateURL,
    sharedStoreAt: sharedURL,
    schema: .nativeIdentity)
let graph = try await database.openGraph(graphID)
let result = try await graph.query(descriptor)
try await graph.close()
try await database.close()
```

For a single resource use openReadOnly(at:schema:). Omitting schema retains
.current; native identity selection remains explicit. Both APIs use ordinary
NSPersistentContainer and existing resources with native read-only descriptions,
no CloudKit identifier/options. Pair URLs retain explicit private/shared routing.
The host resolves authorized App Group URLs and uses the same schema as the app.

The reader never initializes a missing SQLite file, creates a graph, converts
an old protocol or adopts legacy data. Missing first-launch resources produce
GraphStoreError.missingStore; an extension can return an unavailable/placeholder
result until the app creates them. Incompatible resources remain preserved and
require the app's explicit upgrade/cutover. Both paired files must already exist.
Graph mutations and createGraph fail with GraphStoreError.readOnly before their
admitted mutation body runs. Native operation admission also refuses writes;
public sharing methods may first report a local database from their CloudKit
setup preflight. Diagnostics which require CloudKit report a local database. Reading attachments retains checksum/identity
validation; no file representation or ownership changed.

A read-only lease does not bypass the same-process registry's access-mode
compatibility. Use the existing app handle inside its process; the independent
reader path is for another process or a later reopen. It does not implicitly
close, downgrade or clone a writable owner.

## Refresh and suspended processes

Each read uses a fresh scoped context pinned to its current generation. A
subsequent read can see another process's committed changes. Remote-store
notifications invalidate observed queries conservatively; these remain bounded
rescan hints, not a durable stream. A fresh widget timeline should execute a new
query after resume rather than depend on notification delivery while suspended.
No history purging, shared durable consumer token or automatic WidgetCenter
reload is introduced. The library remains independent of WidgetKit.

Cloud setup, application writes, local read visibility and independent cloud
replica recovery remain separate facts. A reader does not synchronize on its
own when the app is not running. Cached participant data is not current server
permission/account proof. Account changes, revocation, cache policy and cleanup
remain PA03 work; this opener cannot certify a safe cloud-account cutover.

## Evidence and remaining gate

Unit tests cover both schemas, missing/incompatible stores, one/two local
resources, attachment reads, mutation-body refusal, same-process exclusion and
extension mirroring preflight before model/native access. The external Swift 6
ProcessConsumer uses two actual macOS processes over new local temporary fixtures:
writer ownership remains live, reader observes 0 then 1 after a parent commit,
a fresh read sees that commit, and attempted writes are refused. It is a
functional check with deadlines, not a timing/performance threshold. A separate
child packaged in a synthetic .appex bundle verifies the real Bundle.main path
and both public mirrored overloads/schemas refuse before native file creation;
this is still not an iOS extension or sandbox test.

These checks do not stand in for an iOS extension, App Group signing/sandbox,
CloudKit owner plus local reader, or suspension/termination evidence. Before
beta, verify those on iOS independently, including widget-before-app, missing
paired resource, protected-data availability, reopen/refresh, account/revocation
behavior and the selected widget write scope. PA02/O03 remain open.
