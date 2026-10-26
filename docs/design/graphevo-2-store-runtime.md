# GraphEvo 2 — A1 store runtime increment

Status: implemented local ownership foundation, 2026-10-26. This is library
source, not another framework laboratory. It implements part of specification
sections 4–5; the [delivery plan](graphevo-2-delivery-plan.md) keeps later
transaction, model, sharing and migration work separate.

## Package boundary and schema

`Sources/GraphEvoRuntime/` is an internal dependency of the existing GraphEvo
target. It and `GraphEvoRuntimeTests` compile in Swift 6 language mode without
unsafe compiler flags, unchecked Sendable declarations or preconcurrency import
suppression. The package requires Swift tools 6.0. The legacy GraphEvo facade
and its existing tests remain in Swift 5 language mode for incremental work.
There is still one public product, `GraphEvo`; no new public Graph API or
separate runtime product is introduced by A1.

The native Core Data schema is unchanged. `Model.makeModel()` constructs a
fresh instance from the existing declaration; `Model.create()` retains its
legacy cached behavior. `GraphRuntimeSchema.current` supplies only immutable
entity hashes, a schema identifier and a fresh-model factory to the new owner.
Native model objects are neither transferred as Sendable nor concurrently
hashed/copied through the legacy global cache.

The first parallel test fixture attempted to reuse/copy that cached native
model and crashed in `_entityVersionHashesByNameInStyle:`. The corrected
boundary constructs independent native models. This is an observed fixture
integration problem and a model-factory design constraint, not proof of a
production v1 crash. The existing model declarations and persistent hashes are
not redesigned in response.

## Implemented contract

The package-scoped entry point is `StoreRegistry.shared.open(_:schema:)`.
It returns a Sendable actor `StoreHandle`. Internal registry initializers and
lifecycle hooks allow isolated deterministic tests; application-facing code
will use the shared registry through the future Graph facade.

| Concern | A1 behavior |
|---|---|
| Resources | One local SQLite file or an explicitly identified in-memory store per owner |
| Compatible opening | Reserve separate lease tokens and await one native opening task |
| Compatibility | Compare resource identity, access mode, schema identifier and entity version hashes; validate factory output against declared hashes |
| Container/context | One NSPersistentContainer per owner; native async performBackgroundTask supplies an operation-scoped private context without transferring a retained context across actor boundaries |
| Read scope | Package-only synchronous body, Sendable result, no retained pending changes; accidental unsaved mutations are rejected and rolled back |
| Handle close | Idempotent; concurrent close calls await one outcome; another active handle remains usable |
| Final close | Stop admission, drain admitted native reads and their context cleanup, detach stores, then release registry ownership |
| Close cancellation | Cleanup continues even if the close caller is cancelled |
| Handle deallocation | Initiates best-effort asynchronous release; explicit awaited close gives deterministic cleanup and errors |
| Reopen during close | Wait for old shutdown before starting another owner |
| Failed open | Release the failed generation; old waiter cleanup cannot remove a newer generation |
| Cancelled open | Do not start a pre-cancelled request; a cancelled waiter releases only its lease after native opening completes; remaining waiters are unaffected |
| Failed shutdown | Retain ownership and the failure, rejecting subsequent opens rather than creating a second coordinator; destructive recovery/retry is not supplied by A1 |

The Xcode 16.4 SDK does not declare NSManagedObjectContext Sendable. Its first CI
build rejected a retained actor-owned context passed to async perform, including
explicit Sendable closures. A1 instead uses native async performBackgroundTask:
the context is a callback argument confined to that operation, not an actor
property sent across executors. This requires neither a retroactive context
conformance nor an unchecked wrapper/preconcurrency suppression. Parallel read
operations may use different contexts; A2 still needs explicit serialized write
admission rather than assuming a shared context's queue is a transaction guard.

The runtime diagnostic UUID identifies an owner generation, not a graph or
node. Snapshots report local ownership only. Each context uses an explicit error
merge policy; no cloud conflict policy is selected by this local increment.
No writes, transaction commits, persistent-history consumer or remote observer
are introduced yet. A2 must define mutation admission, rollback and cancellation
around commit independently of the read-only lifecycle checks.

## File identity and failure policy

The runtime accepts an explicit local `.sqlite` file URL (extension matching is
case-insensitive), not an ambiguous directory. Directory/name resolution,
legacy-store selection and App Group resolution remain above this layer. This
does not modify the v1 GraphStoreConfiguration path rules.

Resolve existing symlinks and the nearest existing ancestor before reserving a
not-yet-created file. The volume's case policy participates in the key, including
case aliases requested before SQLite creates the file. Reject volumes whose
case policy cannot be established, dangling file/directory symlinks, hard links
and detected alternative file identities. A changed inode/device identity at
an owned path is reported before a subsequent read or join. These are in-process
coordination checks, not a filesystem lock or protection from arbitrary external
file replacement between checks and native work. Exotic Unicode/filesystem
alias behavior and out-of-process writers remain outside the verified envelope.

Existing incompatible or unreadable stores are not replaced, relocated or
automatically migrated. Compatibility metadata inspection uses native APIs on
the selected file. Earlier V08 evidence shows that inspection can touch SHM;
A1 does not promise byte-preservation of every sidecar or implement the later
migration backup protocol. Source filenames and logical data remain in place.

In-memory identity is an explicit UUID. Reusing it joins a compatible live
owner; a different UUID creates an independent store. After final close,
reusing the UUID creates a new empty resource generation.

## Verification and limits

`Tests/GraphEvoRuntimeTests/` exercises the current graph schema, including a
fixture populated using v1 Entity/Relationship/Action APIs with properties,
tags and groups, then detached before the v2 runtime opens it. Exact values and
counts survive reopening. This validates schema reuse under the tested setup,
not a v1-to-different-v2-model migration or simultaneous use of both stacks.

Lifecycle tests cover twenty concurrent opens, blocked native opening, cancelled
waiters, failed shared opening, independent handles, close/reopen ordering,
deallocation release, admitted native work and a retained shutdown failure.
Identity tests cover missing ancestors, symbolic links, case rules, hard links,
file replacement, invalid/missing/read-only files and decoding-independent read
scope rollback. Local SQLite and in-memory evidence is distinct from CloudKit.

On 2026-10-26, Xcode 27.1 / Swift 6.4 on the current macOS 27.0.1 host passed
322 legacy tests plus 30 runtime tests. The iPhone 17 iOS 26.5 Simulator run
passed 351 tests and skipped one existing v1 migration-alias test because its
sandbox does not expose the host `/private` temporary-directory alias. All 30
runtime tests ran. The 30-test macOS Thread Sanitizer run passed without a
reported race, with the TSan runtime linked into the test bundle. The separate
package consumer fixture, manifest validation and diff checks passed. These
results do not certify Xcode 16.0 or the deployment-floor OS versions.

Run:

```sh
swift test --filter GraphEvoRuntimeTests
swift test
xcodebuild test -scheme GraphEvo \
  -destination 'platform=iOS Simulator,name=<available device>' \
  -only-testing:GraphEvoRuntimeTests CODE_SIGNING_ALLOWED=NO
```

The deployment floors remain iOS 16/macOS 12. Current host/simulator testing does
not establish behavior on every supported runtime or certify the legacy facade
under Swift 6. Thread Sanitizer checks add local race detection, not proof of
remote-import, app/extension or distributed transaction safety.

CI uses macOS 15 with Xcode 16.4 and an iPhone 16 / iOS 18.5 Simulator selected
for a Swift 6-capable package build, with PR/push coverage for the v2 integration
branch. The initial old iPhone 15/latest destination was absent on that runner;
the selected pair is present in its destination inventory. Xcode's installation is listed
in the official [runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).
The simulator test runner must execute the runtime test target as well as legacy
tests; a successful build or zero-test invocation is not runtime acceptance.

## Next integration boundary

A2 will connect awaited graph operations to these owners and replace context
escape with safe domain operations. Before any public path permits legacy and
v2 owners to coexist, either retire the old opening gateway or enforce shared
ownership exclusion between it and the new registry. A1 leaves the existing
Graph initializer, registry and watchers intact and exposes no public way to
open a second owner through the new module.

Still pending: multi-store/cloud resource sets, actual graph membership and
durable identity, mutation/commit contracts, logical graph handles, subscriptions,
account/permission states, versioned source fixtures and migration conversion.
The v1 source baseline remains available in Git at `4dc0a7f`; extending the
supported source-version matrix and protecting populated user stores remain
mandatory migration work during alpha/beta.
