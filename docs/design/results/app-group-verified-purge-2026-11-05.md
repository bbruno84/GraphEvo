# Store destruction after verified owner exit

This macOS laboratory continuation builds on the
[maintenance admission experiment](app-group-maintenance-admission-2026-11-05.md).
It exercises physical Core Data store destruction on disposable synthetic
replicas. A supervisor can bind a published owner generation to the child
process it launched and directly observe that child's exit. This laboratory
authority applies only to the supervised child and the selected fixture.

The production leave path persists terminal membership and blocks access
before local destruction. Its retry keeps the membership in `purging`
until the exact replica is gone and durable cleanup can complete. All 23
existing `GraphSharingLifecycleTests` passed, including failure and retry,
restart before journal completion, and protection of a replacement store.
The current recovery path opens a terminal native owner before calling
runtime destroy. Integration would need to account for that owner's
registration while refusing claims from other generations, and preserve the
terminal access fence and exact store identity through any retry.

The probe refused deletion while an owner was live, after a controlled
SIGKILL during queued close, and after a cold read and clean close. It left
the store artifacts intact at each refusal. The supervisor reaped the exact
child that had published the old claim and used a one-time proof tied to
that fixture and generation. It refused a live child, a different child,
an invalid or reused proof and a different fixture. The old claim was
removed while another live owner's claim was preserved. Maintenance
remained blocked until that owner detached and cleared its own claim.

With zero claims, the probe still refused mismatched graph and store IDs.
With matching identity, Core Data destroyed the exact replica under the
writer fence and the Apple accessor. The SQLite artifacts and two 4 MiB
external payload files were removed. The neighboring store, an unrelated
file and the stable writer sidecar were preserved. The independent repeat
verified the same results.

## Opening while destruction holds the writer fence

An open-existing request can observe the store before it waits for the
writer fence. If destruction completes during that wait, Core Data can
create a new empty SQLite file. Registry identity validation then rejects
the open, leaving the newly created file at the purged URL. A focused
test reproduced this on the current runtime in a detached checkout.

Checking existence again under the writer fence, before native loading,
prevented recreation in both the process experiment and an isolated
runtime candidate. The candidate passed 36 tests across
`GraphCoordinatorTests` and `GraphSharingLifecycleTests`. This checks the
observed race. Integration still requires review of open, create and
purge recovery admission.

The private probe exercises a cold, closed replica on macOS. The public
leave path on iOS and a supported source of recovery authority for App
Group processes remain open. The independent evidence manifest verifies
25 files. SHA-256
`c920cd4d61c83930bdb6d028ad911cd2a453caf7afa46ee3f0d46660f07bbd5e`.
