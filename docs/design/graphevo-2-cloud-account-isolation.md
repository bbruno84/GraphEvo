# Cloud account isolation

The selected alpha default retains each account's local data separately. Logout,
account switch and restrictions isolate an account-bound graph: normal reads,
writes, queries, attachments and exports fail with `GraphStoreError.accountIsolated`.
No automatic merge, relabel or local deletion occurs. Unbound local graphs remain
usable. Merge and automatic local deletion are separate backlog policies; no
configuration cases advertise unsupported behavior.

## Authority and consumer notification

The ContextManager verifies CloudKit availability and user identity before
starting its private/shared engine pair. It observes `CKAccountChanged`, refreshes
on foreground activation and accepts native engine account events. One authority
serves the configured database pair, rather than one engine per graph.

`GraphStore.cloudAccountState` and `observeCloudAccountState()` remain available
while isolated. The observation publishes an initial and newest current state:
`localOnly`, `available`, `temporarilyUnavailable`, or `isolated` with
`verificationRequired`, `signedOut`, `differentAccount` or `restricted`. It does
not expose account identifiers, certify synchronization, or provide durable event
history. Refreshing this observation republishes local state; it is not a network
identity check. Consumers must replace cached UI when isolation is reported;
already delivered detached values cannot be recalled.

A temporary outage preserves local access only for an already verified identity.
A cold account-bound graph remains isolated until verification succeeds. Temporary
availability cannot undo a confirmed logout, restriction or different identity.
Account state does not override sharing revocation, permissions or migration
reservations. Query/change observers from a previous identity epoch terminate;
consumers create fresh subscriptions after verified recovery.

## Persistence and recovery

A reserved local root property records immutable container/environment/account
ownership. Existing transport, participant and activation metadata are checked
for agreement; conflicting or malformed bindings fail closed. The native S04
schema is unchanged. Unbound historical alpha data needs a verified route claim;
this is not a general migration or public cloud-cutover certificate.

On active-session logout or switch, both native drivers permanently stop offering
records. The manager isolates all known leases, including draining owners and
migration working copies. Pending native scopes and prepared file operations
retain epoch permits: returning to the same account cannot revive old work.

The session clears only SDK engine serialization and persists the optional
`accountResetRequired` marker in its existing format-8 document. PH checkpoints,
frozen attempts, sent receipts, inbox entries and owned asset files remain. On
verified return of the original account, reconciliation creates fresh drivers
and retains those durable queues; it does not replay application transaction
bodies. Engine ownership remains reserved through cancellation and detachment.
A stopped session retains account monitoring without automatically restarting
cloud synchronization.

A different account requires a distinct session directory and graph/store. The
old store is never claimed by the new identity. Host-facing coordinated opening
and account-aware resource selection remain later public integration work;
ContextManager orchestration is still package-only. Independently opened reader
processes/extensions, protected-data lifecycle and consistent multi-file
restoration retain their existing acceptance gates.
Physical account-change trials are scheduled during beta, before stable release,
by the maintainer's 2026-11-04 decision; they are no longer a beta-entry condition.

## Apple behavior and selected policy

Apple's [account-change event](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange)
resets engine bookkeeping and leaves local persistence handling to the app.
Apple lists separate/merge/delete choices for existing local data on
[sign-in](https://developer.apple.com/documentation/cloudkit/cksyncengineaccountchangetype/signin)
and recommends deleting the old cache on
[account switch](https://developer.apple.com/documentation/cloudkit/cksyncengineaccountchangetype/switchaccounts).
GraphEvo's selected retention policy deliberately isolates that cache instead;
physical deletion is deferred. It is an access policy, not encryption or a
security boundary against external file readers.

## Validation scope

Injected availability providers, native account events and an isolated
NotificationCenter name exercise logout, switch, transient outage, restriction,
cold reopen, same-account recovery, stale verification, observer invalidation,
working copies, prepared writers, asset queues and native upload revocation.
These tests do not change a device's personal iCloud account and do not establish
physical account-change or cross-process cached-read acceptance.
