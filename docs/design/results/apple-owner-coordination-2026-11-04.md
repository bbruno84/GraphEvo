# Apple coordination and native owner lifetime — M / M2

2026-11-04. Private experiments on library base
`be14beca8a417cd656dce6de3f4137e896a67da3`, using the actual S04 model and
Graph adapter. macOS 27.0.1 / 26A434, Xcode 27.2 / 27B52; release CLI and
signed Debug device products. This extends the [L presence control](app-group-presence-control-2026-11-04.md).
K/L sources, products and evidence are preserved. No production code, native
schema, public API or CloudKit account/session is changed; no remote CI is requested.

## Alternatives actually exercised

**M: native owner per operation.** NSFileCoordinator grants access to an isolated,
stable directory containing the owned native subtree (SQLite, WAL, SHM and native
external content). Core Data opens, runs the operation and detaches before the
accessor returns. No lifetime owners flock is used. A failed detach retains its
native owner and a refusing presenter, rather than authorizing destruction.

**M2: active logical lease with an Apple presenter.** Opening and presenter
registration happen under coordination. The native stack stays open during the
active lease; ordinary operations use finite coordination requests. The lease's
own presenter is excluded from its coordinator notifications, while foreign
presenters still participate. Administrative delete/replace requests are refused
by active peer presenters. Pause/close stops admission, drains operations, detaches
natively, unregisters the presenter and permanently closes the old lease. Resume
requires an explicit new open; UUID/inode comparison does not resurrect it.
An extension's lease is limited to its operation and closes before intent return.
The presenter refusal uses Apple's
[deletion-preparation callback](https://developer.apple.com/documentation/foundation/nsfilepresenter/accommodatepresenteditemdeletion(completionhandler:));
lease invalidation and reopening remain explicit prototype behavior.

Both prototypes use per-request coordinators, the granted intent URLs (or explicit
moved-target refusal), native autorelease pools and mutation-session cleanup.
The matched performance variants retain the same mutation inventory reuse.

## macOS correctness

The final M matrix contains **16 PASS and one retained FAIL**. It covers first
creation and bounded workspace/bootstrap accessor exclusion, independent processes/tasks with
exact counters, rollback, cancellation before native open and during a body,
concurrent native readers, independent resources, writer admission behind a
coordinated reader, destruction after native detach, presenter refusal, failed
close/recovery, different-store replacement, delete/recreate and real 4-MiB
native external-content copying/validation/destruction.

The FAIL is important: replacing from a native copy can preserve both the source
store UUID and the destination inode/device. M's old UUID/file-identity handle
then remains accepted. It is not a complete logical lease replacement.

M2 exercises that same clone case with two processes: replacement is refused
while the logical lease is active; it succeeds after close; the old closed lease
is refused and a fresh open reads the restored content. Constructed-owner close
failure retains the presenter and blocks destruction until actual detach/recovery.
A close request during an admitted write drains before presenter removal.
The interleaving read-A, write-B, write-A, independent readback-B also passes
with value 2; the reused writer context explicitly unpins its query generation.

M's coordinated reader held a writer for approximately 1.275 seconds during a
1.25-second read hold. This is a concurrency difference from the current runtime's
pinned SQLite reader behavior. M2's local prototype gate/context also serializes
its own reads/writes; that behavior must not be attributed solely to Foundation.

## Physical App Group trial

One iPad (10th generation), iPadOS 27.0 / 24A437, with the independent signed
CoordinationLab host and WidgetKit extension, using a fresh synthetic namespace.
GraphEvo H02 and its data are outside this experiment.

- Idle background transition: native detach and presenter removal precede the
  recorded background notification. The cold widget operation writes 0 to 1 and
  closes its native lease before returning. The same host process refuses the
  old lease; a fresh open reads 1 and validates two records.
- Contention during background transition: the host's three-second write overlaps
  the widget's submitted request. The widget waits approximately 2.952 seconds;
  didEnterBackground is recorded before host commit; draining detach completes
  afterward. The widget's grant follows host commit, detach and presenter removal.
  It writes the third
  value. Both independent native reads return 3 and validate four records.
- Host/extension process identities are retained in the evidence. The old host
  lease is refused again; final native closure completes. No new M2 crash report
  appears in the collected observation window.

These are real lifecycle/request observations, not a certificate of a particular
OS suspended state, indefinite background execution or assertion expiry.

## Bounded cost comparison

Three repetitions, macOS wall-time medians, matched synthetic S04 writes. These
are batch wall times, not individual-request latency or production throughput.

| Native owner strategy | One process, 50 writes | Two processes, 100 writes total |
| --- | ---: | ---: |
| Retained stack control, without logical lease protection | 449.06 ms | 1,135.40 ms |
| M2 active native stack and presenter | 503.73 ms | 1,827.20 ms |
| M open/close for every operation | 1,333.53 ms | 3,459.49 ms |

M2 adds about 12% / 61% to the respective control batches, while avoiding M's
repeated native opening cost. Initial open/bootstrap and final detach are separate
from per-operation body/save measurements. The 18 timed runs verify 1,350 committed writes. An earlier M2 sample with
self-notifications took 27.5 seconds for 50 writes; that result and the stopped
unoptimized repetitions remain separate evidence, not inputs to the final ratio.
These small-fixture results do not
establish a large-store or physical-device performance envelope.

## Decision boundary

M2 is a concrete Apple-based candidate for the next contract discussion, not an
integrated lock replacement. The observable rule is that the old lease does not
survive pause/close; a logical graph selection can remain, but access is reopened.
Keep PA02 and the implementation gate open. Map this lifecycle onto public
GraphContext/GraphStore/observation and the existing admission/cancellation rules
before changing production code.

Partial-load/failed-initialization cleanup is not covered by the constructed-owner
failed-detach injection. Quarantine behavior through suspension remains unaccepted.
The prototype owns an isolated native directory; sibling SQLite files sharing a
parent directory require a separate resource-layout/coordinator design. URL aliases,
hard links and directory moves/replacements have not been accepted by these tests. Prepared
asynchronous work, live migration workspaces across scopes/publication, cloud
session/catalog locks, account
policy and mixed old/new clients are not certified by this local experiment.
No custom persistent marker/epoch is introduced to hide the clone failure.

## Evidence and independent review

Private `REPORT.md` SHA-256:
`f5a18810efe94caf4a8922d529849697268f37932fa58c0c1d7bd3e7bcc4703c`.
Private `Evidence/final-checksums.json` SHA-256:
`b36e2b37330aa88fcad68b7b85d3f7b75169d2b72ea50a0adc0d294f9d6c0258`.

The implementation chat reran `verify_results.py` successfully, independently
checked all 32 manifest artifacts and recomputed every batch median from the raw
18-run results. The verifier checks retained failures, exact native counters,
process identities, zero dropped journal frames, background/commit/detach/grant
ordering, normal closes and the unchanged historical L manifest. The
experimentation chat checked this summary for fidelity; its two clarifications
(invalidation rather than TTL expiry, and detach after the background notification
in the contended case) are incorporated. This is evidence review, not another
runtime/device acceptance. No raw stores, journals, signing files, private reports
or experiment harness enter the repository. Live copies remain diagnostic
snapshots, not certified backups. No new remote CI is requested for this report.
