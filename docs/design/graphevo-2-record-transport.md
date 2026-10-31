# GraphEvo 2 — T01 manual record transport and effect receipts

Status: package-only implementation in [#111](https://github.com/bbruno84/GraphEvo/pull/111)
on `codex/v2-record-transport`, based directly
on reviewed/merged #110 (`900d51a`, exact-head CI `41184685226`). It connects CF01
to the ContextManager's private/shared engines and to exclusive native graph
coordinators. Native S03, CF01 and public signatures remain unchanged. Assets,
sharing UI/lifecycle, automatic scheduling and public activation are later work.

## Portable graph registration

Persisted bindings contain **GraphID and the complete database/owner/zone ID**.
They contain no local store URL or sandbox path. The ContextManager retains the
canonical file URL only in runtime registration, populated by successful graph
create/open. Closing the last consumer can release the native owner while this
runtime location remains available for a later transport lease.

After process restart, application bootstrap opens each graph using its current
sandbox/App Group URL. A restored cloud route alone never guesses or reopens a
historical absolute path. Until a graph is registered, transport reports missingGraph
and preserves queued work. Runtime StoreKey values are comparison identities,
possibly case-folded; never turn them back into file paths. Exclusive store UUID,
PH epoch, graph identity and account/zone binding validate the opened resource.

A closed synthetic store and session directory can be moved into a new container
and reopened with a new ContextManager. Pending archives/IDs and metadata survive;
none of their structural bindings contain the former container URL. Consumer
GraphValue URL values remain application data; this rule concerns library routing.

## Three durable boundaries

| State | Owner / publication |
|---|---|
| PH cursor and coalesced local pending generations | Existing hidden-root PH checkpoint, runtime-owned Core Data save |
| Account/zone binding, frozen attempt, server system fields and effect receipts | Reserved hidden-root `__graphevo_v2.cloudTransport` Data, same native save as its related effects |
| Incoming events, native send results and both engine serializations | One engine-session document, published before subsequent native state advancement |

The graph transport state has format 1 and binds the native store UUID and PH
epoch as well as container/environment/account and zone. State/metadata mismatch
is an error, never permission to reset or create replacement metadata. Native
rows/columns do not change. This is library protocol state, not a consumer format
registry or app-data version.

The engine document is now **format 2**. Older format-1 engine-session files are
refused unchanged before constructing engines. Alpha directories remain disposable
under M13; there is no implicit converter, path rewrite or erasure. The native
store itself is not relabeled or migrated because this document changes.

## Outgoing records

`sendCloudChanges(for:configuration:maximumRecords:)` obtains its own temporary
graph lease. One operation per graph and one network operation per database
scope are admitted; unrelated graphs retain independent local progress.

First recover durable sent receipts, then handle already downloaded incoming
work. Unresolved incoming/local conflicts block a new send rather than allowing
an older queued remote body to overwrite a newly acknowledged local edit. Echoes
with a nonempty native change tag equal to the persisted server version are
already known versions: consume their effect without clearing local pending edits.
Missing tags never establish equality or import completion.

Preparation discovers PH changes and saves an immutable CF01 attempt with its
operation IDs/generations. Its native archives and selected server metadata are
committed before any network request. Reopen returns the same attempt until its
items succeed; it does not rebuild a retry from newer application values. Raw
PH-only acknowledgements and unreceipted patch imports are refused once transport
state exists. Ordinary local editing and PH discovery remain available.

The native driver queues a private-zone save when necessary and exact record
saves/deletes on its existing engine, using a zone-scoped manual send. Shared
sends do not create zones. The provider offers one frozen batch per invocation;
a repeated request gets nil, preventing an unbounded loop on a conflicted record.
A binding or frozen-body mismatch is rejected before offering a different record.

Native send-result events are retained in the engine document before processing
their subsequent state updates. The graph receipt transaction validates the exact
attempt, saves native system fields, removes only matching pending generations,
updates the remaining frozen attempt and stores the receipt fingerprint atomically.
A newer local edit remains pending while learning the new server base metadata.
Partial successes acknowledge only successful records; failures remain explicit.

An ambiguous prior successful save can be recognized on serverRecordChanged only
when the full server GraphRecord equals the frozen desired record. A genuine
conflict remains pending; no last-writer-wins policy or arbitrary replay is added.
An unknownItem result for a requested deletion establishes its intended absence.
Actual native change tags are not fabricated in local fixtures.

## Incoming records and recovery

`fetchCloudChanges` retains events; `applyCloudInbox` explicitly processes a bound
graph's retained work. Record conversion uses the complete trusted scoped route.
Application data and an event-ID/content-fingerprint receipt share one native save,
using the import author. Those changes remain observable and do not feed uploads.
Only then may the session consume the corresponding incoming envelopes.

Already receipted effects are skipped after restart, including when later local
edits changed the record. Reuse of an event ID with different content is refused.
Per-node current-state effects coalesce to the last retained body/deletion in the
selected cut. Deletes are idempotent; saves create entities before relationships
and actions. Existing node kind/logical type cannot change through this transport.
Property removal, tags/groups, endpoints and optional createdDate are preserved.
The adapter uses Node facades, then validates the native graph before commit.

Pending local writes, including inverse/cascade effects, prevent overwrite and
roll back the whole incoming transaction. Missing endpoints retain the inbox for
a later complete cut; no partial invalid graph is published. Zone deletion has
priority over application-body decoding, marks transport unavailable and retains
local data/pending work. It does not silently recreate or purge the zone/store.
Broader account/revocation/cache policy is not closed by this access-reduction seam.

After successful session consumption, local receipt-marker cleanup is best-effort
and reported as cleanupPending if it fails; committed effects do not become
failures merely because that cleanup remains. Before the next operation, prune
only markers absent from the same validated session's retained work. Still-queued
IDs remain protected. Restoring mismatched session/native backups is not certified.

## Bounds and result meaning

Creation selects at most 100 records per attempt (caller may choose fewer).
Resuming an existing frozen attempt preserves its original selection. Existing PH
and CF01 limits still apply. Per-graph transport state is bounded at 32 MiB encoded,
100,000 metadata entries and 4,096 retained receipts. The session's configurable
count budget charges incoming records and individual successful/failed send results;
its byte budget includes the complete document. There is no automatic budget increase.

These are count/encoded-state bounds, not total heap, CPU, I/O, batch/server-size
or production-envelope guarantees. Full graph validation, full retained PH cuts,
metadata maps and whole-document rewriting remain cost/retention measurement gates.
Oversized attempts fail before sending; callers can reduce their creation count.

Reports describe observed successful receipts, failures and handled incoming
envelopes (including replay/echo/zone events), not global sync completion or changed
row counts. transportError preserves network/zone errors alongside results already
recovered; source events remain durable. Account/session failures prevent further
admission. Closing a consumer does not cancel other graphs' engines. Public pause,
automatic scheduling and multi-process writer coordination remain separate gates.

## Validation scope

Deterministic injected transport tests use real S03 stores and the public native
CKRecord coders/provider API. They cover two replicas of all primitives, updates,
cascades/deletes, no upload feedback, partial success, independent graphs, frozen
attempt reopen, stale acknowledgements, both sides of receipt consumption, atomic
pre-save rollback, inverse conflicts, missing endpoints, nil dates, zone deletion,
account mismatch, corrupt frozen archives, cleanup retry and portable container moves.

The first iOS run exposed the prior manager's use of a case-folded StoreKey as a
file URL. The fix retains the actual canonical URL only in runtime registration;
the maintainer then required all persisted routes to be path-free. The final
relocation test validates restart in a different container. Earlier failing runs
are not acceptance evidence.

The in-memory bus does not emulate server change-tag/CAS behavior, CloudKit
permissions or real network scheduling. The native code is connected but physical
private-device delivery, real change tags/conflicts, actual kill/power-loss,
backup consistency, server schema deployment and resource measurements remain open.
No cloud reset or physical-device mutation is part of these local tests. Do not
close beta/stable gates based on simulated delivery.

The complete local checkpoint passes 648 tests (331 legacy, 223 store, 71 runtime,
23 model). Eighteen new transport functions include actual native-store relocation.
The selected iOS Simulator 26.5 run passes 87 functions / 111 expanded cases across
transport, CF01, engine, PH, coordinator and resource-group suites. Package manifest,
diff and Swift 6 consumer checks are required alongside exact-head remote CI.
