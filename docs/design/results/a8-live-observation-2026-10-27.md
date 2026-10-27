# A8 — live query observation through async and Combine

Date: 2026-10-27. Status: positive within the scope below, not beta/stable
acceptance. Read the [A8 contract](../graphevo-2-observation.md) and
[one-use procedure](../../../Experiments/A8NativeProbe/README.md).

## Local verification

The complete local macOS suite passes 462 tests: 322 legacy, 59 runtime,
60 store and 21 model. Twelve targeted tests also pass under Thread Sanitizer
without a reported race: three runtime invalidation tests, six observation tests
and three Combine tests. The independent Swift 6 ModelConsumer exercises both
public async and Combine subscriptions. Package manifest, Release build,
diff formatting and local documentation-file links pass.

Covered behavior includes related-node/action dependency invalidation, direct
ordering, cross-handle edits/deletion, initial registration, slow consumers and
resubscription, recoverable read errors, handle-specific termination, explicit
refresh, demand-controlled startup/delivery, multiple Combine subscribers and
cancellation. Runtime tests retain bounded newest hints, cancellation cleanup
and sticky account-change signals. Injected remote/account notifications test
local routing, not native cloud/account behavior. No new v1 history-token or
Watch delivery contract is inferred.

During implementation, initial builds caught a non-Sendable Combine delivery
value crossing the state lock. The adapter now confines the immutable downstream
in one private audited box and serializes callbacks outside the lock. Temporary
test compile errors around Subscription capture and async assertions were fixed;
passing totals describe the corrected source, not those failed builds.

## Physical environment and retained state

The authorized Development container was `iCloud.com.valerioburiani.GraphCKDemo`.
The owner iPad used iPadOS 27.0; the different-account XR used iOS 18.7.10.
Xcode 27.1 / Swift 6.4 built a disposable configured demo against working A8
source. The original demo checkout/configuration remained unchanged. Native
model hashes and logical schema were unchanged. Source was not yet committed
at runtime; this is working-source evidence rather than an immutable-build claim.

Run `E6F24D18-1696-4E8A-AACC-51F898AC7308` reused the retained A6 run's
existing private/shared stores and accepted A share. A6's owner/files had already
been deleted; its share boundary remained available. No invitation, acceptance,
permission change, new share, cloud reset or account switch occurred. A new
protected run-bound fixture pinned two new Entity IDs and one Relationship ID.
Only that new fixture was transported to XR; sensitive payloads, native logs
and stores stay outside Git. Every stage reserved its own report before work;
there was no failed/replayed runtime stage or mutation retry.

## Independent observations

| Stage | Observation |
|---|---|
| Owner seed | Two A8 entities and a directed edge were saved in retained A; the child's existing scalar state started off. B's original attachment metadata and exact 512 bytes were unchanged. The native owner stayed alive. |
| XR watch | The existing accepted share recovered both pinned entities. Async and Combine related-query observers separately reached initial-empty state. B was absent from the participant catalog. READY was required before the next write. |
| Owner on | Only the child's existing scalar state changed to on. The queried parent was not edited. Both XR observers independently added the pinned parent through its related-node predicate; ON-BOTH was retained. |
| Owner delete | Deleting the child also removed its edge and retained the queried parent. Both already-running XR observers became empty after their present state, producing PASS. B's control metadata/bytes remained exact on the owner. |

No polling, manual refresh or resubscription rescued either related-query
observer. A separate initial all-entity observation established fixture readiness
and was cancelled; it did not refresh the related observers. Reading the report
files over USB was instrumentation, not an application fetch. Owner processes
were retained across independent observation; launch changes reopened the same
retained writer files without replaying writes. The final parent remains pinned
as test data; no cleanup/reset was performed.

This demonstrates actual cross-account import invalidating dependent queries
through both public adapters in one foreground run, including deletion. It does
not attribute delivery to one particular native notification: the implementation
intentionally also listens for context saves and completed native cloud events.
It supplies no cloud-completion timestamp or delivery-time bound.

## Remaining boundaries

Offline/background delivery, restart replay, account switching, revocation/cache
access and migrated fixtures were not exercised on hardware. Sticky account
handling is only injected local evidence. Processing remains live hints plus
explicit rescan; O04's durable replay decision stays open. Query budget refusal
and transient refresh failures do not certify complete import. Multiple observers
currently repeat bounded full-query evaluation; representative costs, downstream
Combine scheduler buffering and the beta-entry consolidation remain in the
[post-alpha checklist](../graphevo-2-post-alpha-checklist.md).

## Review follow-up

Review of the initial A8 head identified two concurrency defects beyond the
retained foreground device scenarios:

- An ordinary publication/refresh can capture accountChanged = false under the
  hub lock, pause, and deliver after an account-change hint. Newest-one buffering
  could then hide the account hint. The package sequence now checks the current
  sticky guard at consumption; the regression injects this exact stale-buffer
  ordering without requiring a real account change.
- Combine cancellation released the last subscriber reference under its state
  lock. Subscriber deinit can synchronously cancel/request again, deadlocking
  that lock. Cancellation now retires state outside the lock; replacement and
  completion likewise retire pending values outside it. A temporary subscriber
  that cancels again from deinit exercises the regression.

These corrections do not change the public API, model or processing scope.
The original physical run did not test these windows and was not replayed.
Review verification is recorded separately in the PR; original 462/12 totals
above describe the initial implementation evidence.

The corrected review source passes 464 macOS tests (322 legacy, 60 runtime,
61 store, 21 model) and 14 targeted Thread Sanitizer tests without a reported
race. The prior physical evidence remains scoped to its original working build;
no new account-switch or destructive-stage hardware result is claimed.
