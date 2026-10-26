# GraphEvo 2 — A2 async operations and transactions

Status: local runtime implementation, 2026-10-26. Read with the
[specification](graphevo-2-specification.md) and
[A1 ownership contract](graphevo-2-store-runtime.md). The current schema stays
unchanged. This increment does not enable mirroring or migrate production data.

## Execution and ownership

The package-internal `StoreHandle` offers awaited `read` and `transaction`
operations with synchronous, throwing, Sendable closures and Sendable results.
Native async `NSPersistentContainer.performBackgroundTask` supplies a fresh
private context for each operation. No blocking `performAndWait` wrapper or
retained context crosses the runtime actor boundary. Both operations reset their
context on completion; failures roll back unsaved changes.

A FIFO writer gate belongs to the physical `StoreResources` owner, shared by
all its handles. It covers the complete body, save and context cleanup. A second
writer cannot read its starting state until the previous writer has finished.
Different stores can write independently; readers do not acquire the writer
gate and cannot see another operation's pending edits. Actor isolation alone
would not provide this guarantee across native asynchronous execution.

A transaction saves once after its body returns. The body cannot suspend and
must perform no independent save, nested operation or external side effect.
Native validation/save errors and body errors propagate; bodies are never
replayed automatically. Read-only store access rejects a transaction before
invoking its body. Reads reject accidental unsaved mutations.

These are **trusted adapter boundaries**, not application APIs. The package
closures receive a raw context and therefore cannot enforce every scope rule
against a malicious/misbehaving adapter (for example, an explicit save in a
read). They must not retain or return contexts, managed objects or facade nodes.
The future application scope must hide these capabilities. Sendable results
alone are not proof of this restriction on every Apple SDK.

The Swift 6 non-UI regression exercises the adapter using the current scoped
Graph/Entity/Relationship/Action facades and returns only strings and counts.
It does not open a legacy container alongside the new owner. Generic native
fixtures test persistence mechanics without manipulating Graph's Managed classes.

## Read view and conflicts

SQLite reads select `.current` query generation before invoking the body. The
native view resolves on the first fetch and stays pinned for the operation;
a regression performs two fetches around a concurrently committed insert and
sees the same rows, while the next read sees the new row. This does not specify
cloud import completeness or an ordering relative to an unrelated writer that
has not committed yet. In-memory reads use native context behavior without a
query-generation snapshot guarantee across multiple fetches.

Transactions use fresh contexts and the explicit native error merge policy.
Serialization covers participating local writers in this owner only, not
external processes, legacy coordinators or remote imports. Same-property remote
conflict policy, stale-write preconditions and domain read consistency remain
beta decisions. The provisional transaction author is `GraphEvo.v2.local`;
per-device/history authorship must be reconciled before connecting observation.

## Cancellation and shutdown

| Boundary | Outcome |
|---|---|
| Before admission | A cancelled task runs no body |
| Waiting for the writer gate | Remove its queued continuation and throw cancellation without waiting for the active writer |
| After transfer of the writer gate | Recheck cancellation on the native context queue before running the body |
| During a synchronous body | Let the body finish, then check cancellation before save; roll back its unsaved edits |
| During a read | Check before and after the body; cancellation does not interrupt arbitrary synchronous body code |
| Immediately before save | The last cooperative check may prevent commit |
| Once save begins | Cancellation cannot promise rollback; successful native completion returns the committed value |
| Final close | Stop new admission, drain active and queued admitted work through cleanup, then detach |
| Cancellation of a close caller | Cleanup continues and admitted writers retain their outcomes |

A small `OSAllocatedUnfairLock<Bool>` transfers cancellation synchronously from
the caller's cancellation handler to native work. No I/O, Core Data access or
suspension occurs under that lock. The writer queue remains actor-isolated.
A cancellation arriving just after the final check may race with save; this is
an explicit boundary, not a promise that task cancellation rolls back a commit.

The v2 macOS minimum becomes **13** to use this Apple synchronization primitive
without an unchecked Sendable wrapper. iOS remains **16**. The maintainer has
authorized deployment-floor changes; these remain provisional v2 choices.
Apple references: [native background execution](https://developer.apple.com/documentation/coredata/nspersistentcontainer/performbackgroundtask(_:)-39sch)
and [allocated unfair lock](https://developer.apple.com/documentation/os/osallocatedunfairlock).

## Integration and remaining work

A2 is stacked on the reviewed A1 branch while PR #70 is pending. Its focused PR
targets `codex/v2-store-runtime` temporarily; after A1 merges, retarget it to
`codex/graphevo-2` before merging. CI also validates PRs targeting `codex/v2-*`
so stacked changes receive the same macOS/iOS checks.

The public `Graph` API remains the v1 facade. Public model scopes and their
non-escaping operations will land together in A3 rather than introducing a
throwaway untyped facade during A2. This is an explicit delivery-plan adjustment:
the local execution/commit foundation is implemented, but the independent public
consumer exit remains pending until A3. Before exposing a new public opening
path, retire the legacy gateway or enforce shared ownership exclusion. No
simultaneous legacy/v2 access to one file is supported by this increment.

Migration remains mandatory. Reusing the schema and testing facade writes does
not yet demonstrate conversion to the eventual v2 model, identity/reference
mapping, cloud cutover or attachment preservation.

## Verification

Regression coverage includes SQLite persistence after reopen, native save
validation failure, throwing-body rollback, forty read-modify-write operations
across two handles, deterministic FIFO admission, cancellation before admission,
in queue, in body and after save, cancelled reads, close with active/queued work,
read-only rejection, independent stores, invisible pending edits, pinned SQLite
reads and current graph-facade writes. Test hooks pause known boundaries; native
blocking fixtures have a bounded timeout and are not production scheduling APIs.

Record executed suites and their environment in the PR. Current-host and
simulator results do not certify the deployment-floor OS versions, remote
conflict behavior or distributed transactions.

Local validation on 2026-10-26 with Xcode 27.1 / Swift 6.4 passed all 322 legacy
and 46 runtime tests on macOS 27.0.1. The 46 runtime tests also passed on iPhone
17 / iOS 26.5 Simulator (no skips) and under macOS Thread Sanitizer without a
reported race. Manifest validation, the standalone package consumer and diff
checks passed. An initial consumer test incorrectly queried the legacy Search
without its required predicate and returned empty arrays; correcting that fixture
made the facade round-trip pass. The superseded simulator attempt was interrupted
before collecting its result; the final 46-test result is the recorded evidence.
Xcode 16.4 / Swift 6.1 compatibility is checked separately by PR CI.
