# Apple owner preparation recovery experiment

The O laboratory addresses the 8 MiB of preparation files left by each controlled
interruption in the [iPad fault continuation](apple-owner-ipad-faults-2026-11-05.md).
It uses the retained Apple owner from a private copy of N and puts the input
files in the executor's private Application Support directory. The host sweeps
its own root on launch. A widget using this preparation path would need its own
recovery hook. The test harness shares a disposable root among cooperating macOS
processes to exercise concurrent recovery.

A stable namespace lock covers directory creation, publication and removal.
Before publishing a job, its preparer acquires a lock on that job's lease file.
A sweep acquires the namespace lock and tries each job lease without waiting.
It leaves a job alone while its lease is held. It can also reclaim a partially
created directory because every creator holds the namespace lock until its lease
is acquired. The process exit releases these descriptors. The namespace lock
file remains in place so participants continue to lock the same inode.

The retained writer takes ownership of the prepared bytes in memory and removes
the temporary directory before entering native write coordination. This applies
to the buffered input path in the experiment. The recovery scope is a dedicated,
trusted root shared by cooperating preparers and sweepers. Files from earlier N
runs, another executor's container and durable transport spools fall outside
that scope.

Ten macOS controls passed. An independent sweeper reclaimed only the terminated
preparer's directory while another preparer continued and produced both exact
4 MiB packets. The matrix covers five interruption points from namespace
acquisition through publication, unrelated entries and symlinks, and task
cancellation during preparation. In the pre-save and post-save SIGKILL trials,
an independent sweep saw empty staging before the signal. Fresh GraphEvo
readbacks recovered respectively zero and one commit with exact IDs, typed
application values and attachment sizes and digests.

The signed iOS build succeeded. Physical validation of the new private staging
path remains blocked by Device Hub access to the Mac. Production adoption still
requires physical iOS fault validation and the coupled synchronization and public
observation lifecycle checks.

Independent review reran the verifier across 420 manifest entries, verified the
prior N hashes and inspected the lease and native readback assertions. Private
report SHA-256 `f972a0a546c51b1b1128bd072cf0d829285b72a9b0d88b2d38b11851f0462ebd`.
Private manifest SHA-256 `2c687b1de5753761e15818c29a9d1de264c096a271ee3ddb920dc1d9b158b834`.

## iOS 18 simulator lifecycle control

A separate copy of N ran on an iPhone 16e simulator with iOS 18.5 (22F77).
An XCTest UI runner pressed Home, tapped the real widget's write button and
reactivated the host. It repeated the sequence thirty times on one fresh
synthetic store. The app and widget used distinct processes throughout the run.
Initial harness attempts exposed test-target platform settings and localized
SpringBoard gallery selectors. The final run passed all thirty cycles.

The retained verifier checked every background notification, native detach,
presenter removal, widget grant, commit and return ordering. It checked old
lease refusal, surrogate observation completion, session and backup lease
release, exact counters, record identities, structured values and both attachment
digests after each reopening. The simulator run covers the normal N lifecycle
with synthetic transport. Physical XR behavior, iOS suspension and termination,
the O staging path on hardware, and production observation remain separate gates.

Private simulator manifest SHA-256
`96c3945f24d058547c9d409601e9ce378d79b0bf582b12216a5e6dbfe3fc59c2` (225 entries).
