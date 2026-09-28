# Store generation rejection investigation — 2026-09-28

## Scope and unchanged behavior

Baseline: `2a81c5e9f6cf304daa29d74c5102366e54edae63` on
`codex/structural-validation`. The application's checked-out
`GraphTransaction.swift` matches the repository file byte-for-byte.
No production code, concurrency guard, retry policy, Core Data model or
migration was changed during this investigation.

The existing guard pins and fetches a private transaction context, then pins
and fetches a fresh probe before saving. A different query generation rejects
the entire transaction with `GraphTransactionError.storeChanged`. This is a
store-wide check, not a comparison of the transaction's read/write set. A
read-only body bypasses that check because there are no changes to save.

Apple describes [query-generation tokens](https://developer.apple.com/documentation/coredata/nsquerygenerationtoken)
as identifying the store generation accessed by a context. Its
[Core Data session](https://developer.apple.com/videos/play/wwdc2018/224/)
describes pinned generations as consistent views despite competing writes.
Neither establishes that a token difference identifies an application-level
conflict or names the writer responsible.

## Reproducible SQLite tests

Run `swift test --filter GraphTransactionGenerationTests`.
The tests create independent SQLite stores and schedule a second private
context's operation deterministically after the transaction is pinned and before
its final comparison. They check that independently fetched contexts agree
before the writer runs and that rejected staged values never reach the store.

| Concurrent operation | Generation differs | Existing write transaction |
|---|---|---|
| No write | No | Commits |
| Save without pending changes | No | Commits |
| Update the property being staged | Yes | Rejects |
| Update a property on an unrelated counts node | Yes | Rejects |
| Add a relationship | Yes | Rejects |
| Insert another node of the target type | Yes | Rejects |
| Assign public store metadata through `setMetadata` | No in this test | Commits |
| Delete Persistent History through Core Data | Yes | Rejects |

A ninth test confirms a read-only transaction retains its old view while a
second context commits; a subsequent snapshot sees the new value.

The history-pruning case demonstrates rejection without a concurrent domain
mutation. It does **not** show that CloudKit pruned history during the device
failures. The metadata-assignment case does **not** simulate CloudKit's internal
bookkeeping or establish that every metadata write leaves generations unchanged.
These are distinct operations and must not be conflated.

## Device evidence

The supplied A/B reconnect and reboot archives were not modified. Each extracted
`current-store` directory was copied again into a disposable investigation
directory, preserving SQLite, WAL and SHM together. No `immutable` connection
was used. History observations below were retrieved through the public
`NSPersistentHistoryChangeRequest` API on those working copies, with mirroring
disabled. The originals and device databases were never opened for writing.

The system reports provide attempt start and recorded failure timestamps.
The retained history gives these observations (UTC, 2026-09-28):

| Attempt | Report interval | Retained application history in interval |
|---|---|---|
| A foreground 1 | 15:12:12.105–15:12:15.794 | None |
| A foreground 2 | 15:12:32.967–15:12:37.986 | Transaction 19, import at 15:12:35.982; seven entity-property updates |
| A boot | 15:13:25.665–15:13:33.972 | None |
| B foreground | 15:12:15.551–15:12:24.722 | None |
| B boot | 15:14:14.739–15:14:26.406 | Transactions 23–26, imports at 15:14:16.068–15:14:16.351; node, property and relationship changes |

An attempt interval is broader than the exact pin-to-comparison window; these
imports are candidates, not proven causes of the final token mismatch. The
absence of a retained history transaction is not proof of no store write:
CloudKit bookkeeping need not appear as an application history transaction,
and these captures are not exhaustive write tracing.

Local view-context transactions also appear shortly **after** the recorded
failures (A: 15:12:17.676, 15:12:39.802, 15:13:34.952; B: 15:12:30.213,
15:14:27.902). The surviving rows include derived counts. Their timing does not
justify blaming them for the earlier refusals.

A quiet write transaction succeeded on each of the four copied stores opened
without mirroring. A second probe using a CloudKit-container instance with a
non-mirroring store description also committed after calling the public identity
lookup on the copied entity nodes. Those lookups returned no identities in this
configuration, so this does **not** test successful identity resolution under
active CloudKit mirroring or exclude that live path from investigation.
The probe inserted only disposable markers into its own copies; it did not
perform the application's reconciliation or alter any original evidence.

## Conclusion and proposed next step

The local tests have not reproduced a generic equality bug: independently
fetched tokens compare equal in a quiet store, including the copied device
stores. The guard is demonstrably broader than domain conflict detection and
can reject bookkeeping work such as history pruning. The exact writer behind
all five live failures remains unproven.

Before changing strategy, collect bounded diagnostics on a new physical-device
run: transaction start, completion of the body, and the final comparison;
generation-equality observations; history interval authors and schema/operation
counts; and nearby CloudKit event phases. Bound the identity-lookup phase as
well. Do not log payloads or label an unaccounted-for generation change as a
confirmed CloudKit metadata write. History collection is diagnostic and must
not become a substitute concurrency guard merely because it omits bookkeeping.

Do not remove the global guard or fall back to winner-row optimistic locking.
A future narrower check must protect all relevant read/write data, relationship
topology and predicate membership, including new duplicate insertions. Imports
can still arrive between a final check and save; an alternative must explicitly
address that existing window. Application retry and payload convergence remain
separate decisions. No retry or replacement strategy is implemented here.

## Validation of this investigation change

- Full macOS suite: 306 tests passed, including nine new generation cases.
- iOS 26.5 Simulator: 26 generation/transaction tests passed with the same outcomes.
- `git diff --check` and `swift package dump-package` passed.
- Production sources are unchanged from the baseline; no physical-device runner
  or MyHomeBills build was started by this investigation.

## Follow-up: opt-in diagnostic capture

The subsequent implementation adds `transaction(diagnosticID:_:)` and
`GraphEvent.transactionDiagnostic`, with an outcome followed by an asynchronous
history supplement. See the [API contract](../api/public-api.md#opt-in-transaction-diagnostics)
for checkpoint semantics, caps and incomplete-history handling. The original
transaction API and global generation guard remain unchanged. The diagnostics
are intended for the next device experiment, not a resolution of its cause.
