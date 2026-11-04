# Apple owner coordination — pre-integration priority protocol

Selected on 2026-11-04, following the
[M/M2 experiment](results/apple-owner-coordination-2026-11-04.md).
This protocol authorizes private laboratory tests, not a production lock
replacement. The shipping runtime and its ownership guarantees remain unchanged.

## Scope and fixtures

Use a separate N laboratory copied from integrated `3638bc4e`, retaining the
original K/L/M/M2 sources and evidence. Exercise the actual S04 model and Graph
adapters where possible. Distinguish prototype orchestration, injected transport,
existing adapter regressions and actual physical lifecycle observations.

The synthetic store contains a counter, notes, serialized arrays, dictionaries
and Codable values, and two 4 MiB attachments. Validate structured values,
identities, attachment byte counts and digests after independent reopening.
No application store, real CloudKit account transition or H02 workspace is used.

The physical matrix is the connected iPad on iPadOS 27.0 and iPhone XR on
iOS 18.7.11, with the independently signed CoordinationLab host and widget.
Use existing provisioning. Keep raw stores, signing material and device journals
outside Git. No remote CI is requested for laboratory or documentation work.

## Priority gates

| Gate | Required evidence |
| --- | --- |
| Partial native opening | Inject failure after adding the persistent store and during initialization, combined with failed native removal. Retain the actual native owner and presenter. An independent process must be refused delete and replacement until verified detachment. Repeat each control three times. |
| Failed close through background | Inject failed close and retain protection. Observe the actual background transition and process outcome; independently reopen and validate data after recovery. Preserve pre-save rollback and post-save committed results without replaying arbitrary bodies. |
| Repeated lifecycle | Run 30 pause/reopen cycles on each physical platform. Reject old leases and new admission during pause, drain admitted work, verify peer writes after fresh open, and exercise concurrent close/cancellation. Old observation delivery must end; new observation must start coherently. |
| Async and attachments | Exercise cancellation while waiting for coordination, preparing files, mutating natively, before save and after save. Native work must finish before coordination is released. Verify exact rollback/commit results, both attachments and cleanup. |
| Synchronization ownership | Use actual manager/session and durable disk paths with injected transport. Exercise incoming work, outgoing confirmations, temporary unavailability and account change at pause. Preserve inbox/outbox/checkpoints, reject retired callbacks and retain a single synchronization owner. Inspect the real session-directory and backup-catalog locks, including an App Group directory. |
| Physical host/widget | Establish independent process identities, background/commit/detach/grant ordering, exact native readback and widget detach before intent return on both devices. Normal paths must not terminate. |

For injected failed-close paths, data safety takes precedence over process
survival. OS termination can be an acceptable error outcome only with protection,
restart and integrity evidence. Controlled termination is a separate recovery
fault test; it cannot establish an OS suspension or termination result. An
observation window without termination must be reported with its duration.

Thirty logical pause/reopen cycles do not establish thirty physical background
transitions. State both counts. A laboratory observation stream does not certify
the public observation implementation. Existing cloud tests do not establish
coupling to the new presenter lifecycle. A synchronous coordination accessor
returning after spawning a Task does not protect that Task's later work.

Audit actual lock release, rather than inferring it from foreground notifications:
the current cloud session releases its directory lease during awaited stop;
foreground-inactive notification alone does not stop it. A stopped actor remaining
allocated must not be misreported as retaining that released lock.

## Costs

Retain three matched repetitions against the final M2 control. Separate native
owner open/close, coordination wait, body and save costs. Verify committed counts
and exclude aborted runs from final medians while preserving their evidence.
Ordinary writes must retain the active native owner rather than reopening for
every operation. Report measured costs without inventing acceptance thresholds
or extrapolating small fixtures to large stores.

## Decision and deferred acceptance

Report each gate as PASS, FAIL, PARTIAL or BLOCKED, with the exact implementation
and platform scope. Missing or surrogate evidence keeps the relevant gate open.
Do not recommend production integration while a priority gate remains unproven.
Retain a deterministic evidence verifier, raw outcomes and checksums; independent
review must inspect the assertions and failures as well as running the verifier.

Sibling-store layout, aliases/hard links and directory moves, persistent migration
workspaces, extreme holds/background expiry, live CloudKit and remaining supported
platforms are outside this priority tranche. They remain mandatory acceptance
work before beta unless an explicit supported-contract decision excludes a case.
No priority pass closes PA02, adopts the public lifecycle contract or authorizes
coexistence with old uncoordinated writers.
