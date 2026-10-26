# V03 — cancellation and process boundary (2026-10-26)

The standalone `ConcurrencyProbe` package in GraphEvoDemo was run on the
current Mac with Xcode 27.1 in Swift 6 language mode and complete concurrency
checking. The same 11 tests passed on an iOS Simulator using the
`ConcurrencyProbe-Package` scheme. This is direct local Core Data evidence,
not a GraphEvo v1/v2 API contract, CloudKit test or iOS App Group result.

The added deterministic commit gate showed that cancelling the caller while
its work is inside `NSManagedObjectContext.perform` does not by itself cancel
the save. `Task.checkCancellation()` inside that closure did not see the
caller cancellation on this runtime. An explicit `withTaskCancellationHandler`
signal checked before `save()` caused rollback and left no row. Cancellation
after a durable save did not undo it. A save already running when the owner
closed finished before store detachment and survived reopening. These are
different timing contracts; no post-commit cancellation is reported as a
rollback. Cancellation while queued behind another context operation remains
to be measured.

Two independent `ConcurrencyProbeWorker` processes then opened the same
temporary SQLite store, outside the process-local registry. Racing creation of
an absent key yielded duplicate rows, rejected by the probe as
`duplicateKey`. In a fresh store with one preexisting row, one process
completed 100 increments while the other received Core Data merge error
`NSCocoaErrorDomain:133020`. The actor registry therefore does not provide
cross-process ownership or a conflict policy. The experiment does not imply
that a GraphEvo 2 app/extension pair must use an application-level file lock;
the supported process topology and merge policy still need a dedicated iOS
App Group test.

No managed object was transferred between actors. Context operations returned
immutable `Sendable` values. The small cancellation signal is protected by
`NSLock`; its lock is never held across suspension.
