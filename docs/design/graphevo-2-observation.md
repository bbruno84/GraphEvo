# GraphEvo 2 — A8 observation and Combine

Status: alpha implementation candidate. Read with specification S10,
[A7 queries](graphevo-2-queries.md) and the
[post-alpha gates](graphevo-2-post-alpha-checklist.md). Native schema, logical
identity and attachment ownership are unchanged. This increment does not close
the migration feasibility or beta-entry review.

## Three consumers, two delivery contracts

One-shot query/count/projection/aggregate/traversal operations remain A7 APIs.
`GraphStore.observe(query)` adds an asynchronous sequence of detached typed
current query states. `changes()` provides bounded live invalidation hints for
consumers that explicitly rescan/reconcile local state. These are distinct from
an ordered durable stream of per-node mutations.

The A8 processing candidate is live invalidation plus rescan. O04's stable-release
choice of durable replay remains open for consolidation. There is no persisted
consumer cursor, acknowledgement, history retention/purge policy, old deletion
payload reconstruction or exactly-once side effect guarantee. Applications must
rescan on startup/resubscription and reconcile their own previously processed
inventory, including disappeared IDs. Work requiring every intermediate change,
retained deletion content or recovery after a crash is not supported by this
live feed. Selecting durable processing would require additional implementation
and acceptance; do not mark it satisfied by these signals.

## Async current state

```swift
let observation = try await graph.observe(query)
defer { observation.cancel() }
for await state in observation {
    switch state {
    case .value(let result): render(result.items)
    case .failure(let error): showUnavailable(error)
    }
}
```

The subscription is installed before the first query. A save racing the initial
read queues another refresh. Each native refresh uses a fresh A7 read scope and retains
its local-view identity, budgets, typed decoding and moving-page semantics.
An observation represents the current first page; a descriptor with an `after`
cursor is rejected before subscription. Sort/limit remain supported. Count and
other specialized outputs currently use one-shot operations or a changes-driven
rescan rather than separate specialized observation APIs.

Both invalidation and output have newest-one buffering. A worker per exact query/model/budget group executes reads
serially; no task is allocated per notification. A slow reader can skip initial,
intermediate and failed states superseded by a newer state. It receives no
per-commit delivery guarantee, frozen multi-page view or permanent error history.
Unrelated invalidations can emit duplicate/equivalent results; application model
code does not need Equatable and no opaque equality promise is inferred.

A query budget, invalid envelope, application-decoder error or incomplete imported
structure produces `.failure(error)`, replacing the prior current state. A later
invalidation or `refresh()` retries; no automatic timer or blind write retry is
introduced. A failed read does not establish permanent corruption or completed
import. A closed handle ends the stream. Buffered values may drain on normal
termination, as with AsyncStream; termination is not a callback-delivery barrier.

`GraphObservation` is single-consumer. Keep either it or its iterator while
consuming it. Explicit `cancel()`, task cancellation while awaiting iteration,
or dropping the observation and iterator releases the worker/registration.
Breaking a loop while retaining the observation requires explicit cancellation.
`refresh()` requests another local read; use it on foreground/resume or after
resolving an external condition. There is no automatic background execution.
Resubscription starts from current local state. A stream does not keep a second
resource lease or make handle close a cloud export barrier.

## Native invalidation and dependencies

The shared runtime owner observes saves from contexts using its coordinator,
coordinator remote-store notifications and completed native cloud events. SQLite
resources enable remote notifications alongside persistent history even without
CloudKit. Trusted native operations invalidate on settlement, including errors
that may have persisted partial effects. These are read hints, not proof of an
application transaction, its author, changed IDs or successful native operation.

The alpha conservatively refreshes every subscription in that native resource
group. It does not filter by graph/model/property/FRC membership. A related
Entity property, action endpoint, relationship deletion, attachment content or
hidden membership change can therefore invalidate a query without editing any
returned node. This closes the V07 dependency gap by over-invalidation rather
than claiming a minimal dependency index. Other logical graphs can cause an
unchanged result to be emitted. Each read still enforces its selected graph's
identity/membership boundaries; hints do not imply other-graph data exposure.

Resource subscriptions belong to a handle token. Closing one handle ends its
feeds while other leases/observations survive. Final resource close removes
observers and finishes feeds. Notification handlers only yield Sendable hints;
no managed object/context reaches the consumer and no downstream callback runs
under a persistence lock or mutation scope.

A native account-change hint is sticky for the lifetime of that runtime owner;
ordinary save/manual refresh hints cannot mask it. Consumption rechecks the
current account guard, because an ordinary publisher may already have captured
a pre-change snapshot before delivering outside its lock. Query observation emits
`GraphObservationError.accountChanged` and ends rather than starting another
cached query. The host must stop displaying old state and re-establish its
account/store access policy. Already in-flight/buffered values are not revoked.
This is an observation guard, not a complete account/cache security policy or
a synthetic account-switch validation; D09/PA03 remain open. Reopening one
handle on a still-shared old runtime does not clear the sticky hint.

## Combine assessment and adapter

Apple documents [Publisher.values](https://developer.apple.com/documentation/combine/publisher/values-1dm9r)
as an async interface to a publisher, and
[subscriber demand](https://developer.apple.com/documentation/combine/processing-published-elements-with-subscribers)
as delivery control. Neither supplies graph dependency invalidation or durable
history. [Native remote notifications](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes)
are suitable invalidation hints; selective per-change consumption would require
history analysis and its own delivery policy.

Keep async observation as the core contract and offer Combine as a cold adapter:

```swift
let cancellable = graph.publisher(for: query)
    .receive(on: DispatchQueue.main)
    .sink(receiveCompletion: handleCompletion, receiveValue: handleState)
```

Every subscriber owns an independent observation and model-decoding/delivery worker;
exact shapes on one handle share native reads. Creation waits until
first positive demand. After startup, demand controls downstream delivery, not
Core Data saves, CloudKit import or when the observation refreshes. A single
pending output mailbox keeps the newest value when demand is exhausted or a
callback is slow. Source/output/mailbox buffers are all bounded; they can retain
multiple full snapshots in aggregate and are not a total memory cap. Downstream
operators/schedulers such as receive(on:) may introduce their own queues outside
this allowance; consumers must select appropriate buffering/throttling there.

The adapter serializes value/completion delivery on a private queue and never
invokes downstream while holding its state lock. Subscriber and pending-value
release also occurs outside that lock, including cancellation and completion,
because application deinitializers can synchronously reenter the subscription. It accepts added/reentrant
demand and cancellation; a callback already admitted may settle after concurrent
cancellation. A finishing stream may discard a pending value without demand to
deliver completion. Startup/descriptor errors terminate with Combine failure;
recoverable refresh errors remain `GraphQueryState.failure` values.

The private audited subscriber box confines Combine's non-Sendable subscriber
behind serialized delivery; the runtime/model APIs remain actor-agnostic.
UI consumers select their delivery scheduler explicitly. Cancellation tears down
only that subscriber. `changePublisher()` adapts the same live rescan hints.
Do not replace this contract with an unbounded subject/Task-per-notification
bridge or assume Publisher.values supplies durable buffering/replay.

## Acceptance and remaining work

Local tests exercise related and action dependencies, ordering, other handles,
failures/recovery, slow readers, lifecycle, source registration, explicit refresh,
Combine demand/multiple subscriptions/cancellation, and injected native hints.
An injected notification is not actual CloudKit import evidence. See the separately retained [physical result](results/a8-live-observation-2026-10-27.md)
for the actual iPad/XR async/Combine related-query and deletion run. Existing Persistent History consumers and v1 Watch remain
unchanged; this increment neither consumes nor purges their cursors.

Consolidation must assess repeated full-query costs with many observers and
file-heavy graphs, native remote/background/account/access-change coverage and
O04's durable-processing choice. Migrated fixtures, full account/cache policy,
app integration and mandatory v1 local/cloud migration still gate beta/stable
under the delivery plan. A8 implementation is not permission to declare beta.


## C04 consolidation adoption

The first consolidation increment routes public `observe` and `publisher(for:)`
through the C04a coordinator, owned lazily by one GraphStore actor. The actor
creates it before suspension so concurrent first subscriptions cannot create
independent coordinators. Its idle graph reference and native-source factory are
weak: an empty coordinator cannot retain its owning handle in a cycle. Active
observations retain the existing handle as before; final cancellation/drop retires
the group, native source and workers. The explicit laboratory remains available
for deterministic checkpoints, independently of the public handle coordinator.

Group only an exact validated query definition, concrete Swift model, row limit
and every candidate/payload/traversal budget dimension. Cursor observations remain
rejected. One detached native output/local view is shared, including its actual
scopeID and diagnostics. Each consumer constructs its own application models on
its own worker, with bounded newest input/output buffering and independent
application-decoder failure, cancellation and Combine demand. An application
must not treat scopeID as a unique subscription ID or model-instance identity.

There is no result replay. A join queues a new read; it cannot receive one begun
before it registered. Its fresh read may also update existing group members.
Likewise, refreshing one member can refresh the entire group. Native query errors
are shared read failures and retry on future hints; decoder errors stay local.
Broad relationship/action/attachment/account invalidation remains in place.
`changes`/`changePublisher`, O04 processing and default native schemas are unchanged.
The package-only independent A8 path remains a benchmark control; public APIs
never select it. The shared benchmark now exercises the actual public path.

The [C04a measurements](results/c04a-shared-observation-2026-10-27.md) select this
architecture but do not constitute a product latency/RAM guarantee. Startup
still requests fresh reads and can refresh older subscribers, and different
queries retain independent native scans. Heavy/slow decoder workloads and real
native import/account/access-change checks remain required before promoting the
consolidated branch; local injected source tests do not close those gates. This
increment is an alpha implementation PR, not beta entry or a schema freeze.


The [public-path verification](results/c04-public-observation-2026-10-29.md)
records 497 local tests, 28 selected sanitizer tests and 36 fresh Release rows.
It retains the one-sample mixed regression and independent five-repetition check;
these are wiring/regression evidence, not a new supported performance envelope.
