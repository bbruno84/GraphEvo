# GraphEvo 2 — T05 per-graph synchronization pause

Status: package-only increment integrated through reviewed #117 into
`codex/graphevo-2`, directly from reviewed/merged #116 (`3b495ba`). Read with [T01](graphevo-2-record-transport.md),
[T03](graphevo-2-conflict-policies.md) and [T04](graphevo-2-cloud-assets.md).
S03, wire formats, graph/engine documents and public opening paths are unchanged.

## Contract and API

Pause is an orderly synchronization admission boundary, distinct from engine stop,
store closure and migration exclusivity. The ContextManager owns one process-local
control per graph, shared by that manager's handles.

```swift
enum GraphCloudSyncState { case active, pauseRequested, paused }
func cloudSynchronizationState(for id: GraphID) throws -> GraphCloudSyncState
func observeCloudSynchronization(for id: GraphID) throws -> AsyncStream<GraphCloudSyncState>
func pauseCloudSynchronization(for id: GraphID) async throws
func resumeCloudSynchronization(for id: GraphID) throws
```

All declarations are package-only and actor-isolated. They require an open graph.
Pause requests synchronously change active to pauseRequested before waiting.
They reject new graph send/import cycles with graphPaused. If no synchronization
work is admitted, the state immediately becomes paused. Otherwise the state stays
pauseRequested until admitted work settles successfully or with an error. Errors
still belong to the original operation and durable work is retained; the pause
wait completes when synchronization admission has drained, not when all data has
successfully synchronized.

Repeated pause calls join the same requested state with independent waits; pause
on paused is a no-op. Caller cancellation before admission makes no request.
Cancellation after requesting affects only that caller's wait and never reverses
the request or cancels the engine. Resume on active is a no-op. Resume during
pauseRequested throws busy; callers must let the existing request settle first.
Resume from paused enables new explicit operations without launching automatic
work or replaying mutation bodies. Another caller may resume after pause completes;
pause is not a separately owned exclusion token.

Observation is a current-state projection with an initial value and one newest
buffered value. Slow consumers may coalesce transitions; it is not a durable event
log. Streams end after the final native owner and admitted synchronization work
have closed. State lives only in the owning manager/runtime; full close and reopen
or process recreation starts active. A reopen already waiting for native detach
uses the same generation-checked retirement/reset path as the closing caller.
Closing one alias does not reset another
handle's pause. Failed native detachment retains ownership and does not erase it.
Stopping/restarting the CloudKit session while the graph remains open preserves
its pause; stop and resume do not implicitly substitute for each other.

## What drains

Admission is recorded before the first suspension of a graph transport cycle.
The cycle includes route/identity validation, checkpoint pruning, preparation,
network send, all grouped receipts, current-local conflict resolution, the bounded
single targeted retry, durable effects, envelope consumption, cleanup and lease
release. Existing admitted cycles can finish internal steps after pauseRequested;
new unrelated cycles cannot borrow their admission.

A database fetch snapshots its currently eligible bound zones and records admission
for each before starting the native fetch. New fetches exclude requested/paused
graph zones; if all bound zones are paused, no native fetch starts. An unbound scope
retains the prior control-only fetch behavior. An already admitted multi-zone fetch
finishes and retains its envelopes. Applying those envelopes is a separate admitted
operation: if not already started before the pause request, it waits until resume
(the explicit apply API reports graphPaused). Pending data is never discarded.

Global database/account notifications and engine serializations may still be
retained while a graph is paused. No paused graph application data is applied by
those callbacks. The live backend still uses automaticallySync=false and native
zoneIDs scopes. This increment does not introduce background scheduling. Other
graphs retain their own admission; the existing single network operation per
database scope, shared state budgets and account failures still apply. Pausing
one graph never calls cancelOperations on their common engine.

## Local changes and async attachments

Local mutations, reads, queries and PH discovery remain available with their
existing ownership, integrity and permission checks. Changes are durable in Core
Data/PH and reduce into the same pending checkpoint on demand. There is no second
queue, automatic history purge or pause-specific timestamp/schema change. A frozen
send acknowledges only its own generation; later local edits remain pending.
Imports already admitted use the existing policies and atomic structural refusal.

A T04 missing-content refresh now owns admission across fetch and graph application,
even if its UI waiter cancels or times out. Existing local attachment copies remain
local operations while paused. A new missing-content refresh is refused when its
graph cannot be admitted. Shared database fetches return their selected graph IDs;
a resumed graph absent from an older shared cut performs one explicitly targeted
fetch under its already-admitted refresh permit before applying its inbox. This
prevents treating another graph's successful fetch as coverage of a paused zone.
Framework busy/errors remain visible and preserve work; this is not a new retry loop.

## Limits and migration boundary

Pause does not prevent local/external writers, provide a distributed lock, persist
migration intent, guarantee an account is available, certify import completeness,
or produce a backup. Protected consumer migration still needs its separate local
exclusive-access/readiness/backup contract. A long pause can accumulate work subject
to the existing PH/pending/inbox/byte bounds; none is silently increased or discarded.

The [T05 protocol](../../Experiments/GraphPauseProbe/README.md) separates actual
zone filtering/recovery on devices from deterministic in-flight barriers. Local
regressions cover queued generations, cancellation/idempotence, success/failure and
commit/rollback draining, current-state observation, all-paused fetch suppression,
alias/close/stop lifetimes, attachment refresh cancellation and resumed-zone coverage.

Apple contracts: [manual synchronization](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/automaticallysync),
[fetch zone scopes](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchangesoptions/scope-swift.enum),
and [send completion](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/sendchanges(_:)).
