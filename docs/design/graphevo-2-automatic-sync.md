# GraphEvo 2 — T06 foreground automatic orchestration

Status: package-only increment on `codex/v2-automatic-cloud-sync`, directly from
reviewed/merged #117 (`f459ae2`). Read with [T01](graphevo-2-record-transport.md),
[T03](graphevo-2-conflict-policies.md), [T04](graphevo-2-cloud-assets.md) and
[T05](graphevo-2-sync-pause.md). S03, wire and persisted document formats do not
change. The scheduler stores hints and retry timing only; PH, inbox, frozen
attempts and receipts remain the durable sources of work.

## Activation and package interface

GraphContextManager adds:

```swift
func setAutomaticCloudSynchronizationActive(_ active: Bool, configuration: GraphCloudConfiguration) async throws
func requestCloudSynchronization(configuration: GraphCloudConfiguration) async throws
func notifyRemoteCloudChanges(in scope: GraphCloudScope, configuration: GraphCloudConfiguration) async throws
func automaticCloudSynchronizationStatus(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphAutomaticSyncStatus
func observeAutomaticCloudSynchronization(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> AsyncStream<GraphAutomaticSyncStatus>
```

All declarations are package-only. An explicit existing session is required.
Automatic work is initially inactive; ordinary opens/manual transport retain their
contract. Activation does not create a second engine, expose a public opener,
change conflict policy or resume a user-paused graph. The app forwards aggregated
scene activity, not individual-scene disappearance, and only container-matched
private/shared notification hints. Notification handlers schedule work and return;
they do not execute transport. Inactive hints are retained in memory for activation.

The disposable demo bridge wires these callbacks while retaining explicit launch
receipts and foreground UI. The production demo's ordinary v1 flow is not replaced.
No APNs delivery, background execution, BGTask or silent-launch guarantee follows.
CKSyncEngine remains automaticallySync=false; the manager invokes its existing
explicit operations. Polling occurs only while automatic orchestration is active.

## Work and local hints

One automatic worker runs per database scope. It round-robins open, ready, bound
graphs and uses the same admission, server metadata, effect/receipt transactions,
100-record batch and single T03 targeted retry as explicit operations. New private
zones are bootstrapped by an initial graph turn before the scope fetch: existing
send logic creates their zones when pending records exist. The scheduler does not
introduce an independent zone writer or infer sharing from a zone name.

Subscribe before the first PH scan. The coordinator's base runtime handle owns the
subscription; the scheduler acquires no permanent graph/store lease. Subscription
filtering occurs before newest-only buffering: context saves authored by
GraphEvo.v2.import or GraphEvo.v2.syncMetadata are excluded. Other authors, including
nil/unknown, request verification; PH retains its strict author checks. Normal query
subscriptions keep their existing invalidation behavior and initial/account signals.
No row, context, record snapshot or payload is retained in scheduler hints.

Consumer bursts debounce for 250ms, with a maximum of 1s from the first hint.
Activation, graph opening/binding, pause resume and explicit requests trigger immediate
reconciliation. A 60s monotonic timer requests both remote recovery and local PH
verification. Notifications anticipate that timer; they are not required for
foreground eventual catch-up. Concurrent requests coalesce into work flags.
Backlogs continue in later round-robin turns. The timer never silently increases
PH, pending, inbox or byte limits.

Fetches aggregate currently eligible open graph IDs and T05 excludes paused zones.
A periodic tick during a cycle retains one subsequent request. Graph turns apply
retained remote work and receipts through the existing send path before preparing
local changes. Other scope workers can progress independently. Existing manual
calls and asset refresh retain their busy behavior; an automatic busy response
waits at least 1s before another attempt. Consumer bodies are never replayed.

## Lifecycle, retries and status

T05 owns graph synchronization admission. Paused graphs retain work but admit no
new network/import cycle. Resume wakes their work and requests remote catch-up.
Inactivity suspends timers and new automatic work without changing user pause or
cancelling the shared engine. Admitted operations may finish subject to system
runtime availability. Stop disables scheduling before existing native stop/drain;
failed native cleanup retains its claims. Successful stop removes the scheduler.
Restart requires explicit graph registration and activation; initial scans recover
existing PH/inbox/receipts. No paused/active flag or retry deadline is persisted.

Activity requests have monotonic revisions, so late activation cannot override newer
inactivity. Session stop rejects reactivation; cleanup is tied to the opening
generation, including failed startup. Subscriptions/work use coordinator generations. Final close removes their feeds;
late old-generation results cannot update a reopened graph. Timer/feed tasks use
weak scheduler references while idle; explicit shutdown drains admitted workers.

Transient network/service/rate-limit/zone-busy failures retry after 5,15,30,60,120,
then 300 seconds, with jitter 0.8...1.2 and a final client cap of 300s. Respect any larger native
retryAfter advice. Advice travels transiently through delegate/session/report
values; no receipt or document format changes. New hints and timer ticks do not
shorten backoff. Success resets it. Remaining T03 collisions and receipt cleanup
also wait before another cycle. Clock and jitter are injectable in tests.

Graph-attributed permanent/structural/permission/quota/limit failures block only
that graph. Mixed partial failure with any permanent item blocks instead of
repeatedly retrying it. An explicit request can reconsider a repaired graph;
notifications/ticks cannot. An unattributed scope-fetch failure blocks/retries its
scope; no speculative graph attribution occurs. Sticky session/account failures
remain blocked across explicit hints and require the existing stop/start recovery.
Files, pending work and receipts are never reset as retry policy.

GraphAutomaticSyncStatus exposes suspended, idle, running, waitingRetry or blocked,
remaining retry delay, a payload-free error family/code and pendingWork. This is an
operational projection, not a convergence certificate. The newest-only stream has
an initial value; intermediate transitions may coalesce. Paused/inactive status is
separate from T05's pause state. A shared fetch marks its participating graphs as
running. Closing a graph/removing its generation terminates old subscriptions. Recheck
the generation after every awaited session check before publishing a turn result.

## Verification and retained gates

Deterministic virtual-time tests cover debounce/max latency,60s catch-up, filtering
before coalescing, round-robin/multiple scopes, all retry steps and retryAfter,
partial failures, independent graph progress, pause/inactivity, sticky account,
generation replacement, stop and weak timer/feed lifetime. Actual S03 store tests
exercise post-activation commits, empty imports without feedback, frozen/newer
local edits, unknown-author rejection and durable pending recovery after restart.

The [device protocol](../../Experiments/AutomaticSyncProbe/README.md) uses new
zones/stores on same-account iPad/iPhone and actual aggregate scene activation.
No manual send/fetch/apply is used to force a passed stage. Physical results are
recorded separately with their pinned runtime. Broader sharing/permissions,
background/APNs delivery, crash/backup, scale, long offline backlogs, polling cost
and protected migrations remain post-alpha gates.
