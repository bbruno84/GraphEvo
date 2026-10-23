# GraphEvo 2 — framework verification roadmap

Status: experiment plan, before the normative specification. No experiment
results are implied by this document. See the [design outline](graphevo-2-outline.md)
for requirements R01–R05 and decisions D01–D14.

## Purpose and method

Use GraphEvoDemo as a laboratory to learn what Core Data and
`NSPersistentCloudKitContainer` support before committing to the v2 architecture.
Keep two kinds of experiment distinguishable: direct framework experiments that
isolate Apple behavior, and GraphEvo integration experiments that exercise the
library. Current v1 behavior must not be mistaken for a framework limitation.

Use disposable stores and a dedicated CloudKit Development configuration with
synthetic data. Never repurpose production stores or purge production zones.
Account-specific identifiers remain local configuration, not tracked files.
Do not change the demo's normal graph-opening gateway to accommodate experiments;
define a separate, explicit experiment boundary when implementation begins.

Each experiment must have a reproducible fixture, an observable expected
outcome, and a retained result. Record the tested OS/toolchain and hardware,
source revisions (including local changes), model/configuration, data volume,
steps, errors, relevant diagnostics, and cleanup. Avoid payloads or account
identifiers in committed evidence. Repeat relevant scenarios after relaunch.

Classify conclusions as documented, observed under stated conditions,
unsupported, inconclusive, or blocked. Successful local tests do not prove cloud
synchronization. An import/export event alone does not certify graph completeness.
Unexpected results should be reproduced in a minimal framework case before
being attributed to Apple or used to redesign GraphEvo.

## Verification sequence

### V00 — recover and assess GraphEvoDemo

Initial inventory and build evidence are recorded in the
[demo assessment](graphevo-demo-initial-assessment.md). Runtime and cloud checks
remain separate from that assessment.

- Inventory the local checkout, uncommitted work, branch, dependency revision,
  targets, schemes, feature coverage, tests, entitlements, and identity setup.
- Check build and available tests without overwriting existing work or changing
  the selected GraphEvo dependency just to obtain a passing result.
- Identify reusable screens, fixtures, diagnostics, and missing laboratory tools.
- Exit: a bounded assessment distinguishes inspected code, successful checks,
  failures, and untested runtime/cloud behavior. Propose recovery work separately.

### V01 — cloud separation of independent graphs

Priority: first framework feasibility experiment; R01 and D01/D10.

- Compare two independent local stores using the same model and cloud container;
  record supported configurations and the actual cloud mapping without assuming
  one store creates one private zone.
- Create distinguishable graphs A and B without sharing either. Check whether
  each remains independently identifiable and accessible on another device and
  after a fresh local replica. Keep graph identity distinct from local filenames.
- Determine whether supported APIs provide the required cloud boundary, what
  data each store imports, and whether opening/removing one affects the other.
- Investigate alternative supported mappings only as needed, documenting their
  provisioning, lifecycle, scale, and platform constraints.
- Exit: state which separation guarantees are supported, which are only logical,
  and which remain unavailable or unverified. Return any incompatibility with
  R01 to discussion before selecting a topology or changing the sync stack.

### V02 — sharing between separate accounts

Depends on V01 findings; D05/D09/D10/D14.

- Use two accounts and a graph containing entities, relationships, actions, and
  dependencies; test invitation, acceptance, subsequent edits, and relaunch.
- Verify owner/participant store placement and graph identity on each device.
- Test read-only permission, offline edits, concurrent edits, revocation, leaving,
  and account changes, with an unrelated graph as an isolation control.
- Record what is removed locally and remotely and which errors/states are
  observable. No cross-graph relationships are allowed.
- Exit: an owner/participant behavior matrix and supported sharing boundary;
  no assumption that a share corresponds to one local SQLite file.

### V03 — concurrency, ownership, and local transactions

R02 and D01–D04/D14; may run locally while cloud prerequisites are arranged.

- Build a Swift 6 language-mode consumer with complete concurrency checking.
- Exercise native asynchronous context access, two handles to one store,
  independent stores, private-context reads/writes, and pending-edit ownership.
- Test conflicts, rollback, cancellation around commit, context invalidation,
  closing/reopening, and concurrent remote imports where applicable.
- Separately verify app/extension access to an App Group store; in-process
  coordination is not evidence of cross-process serialization.
- Measure main-thread responsiveness and expose unsafe object transfers or
  lock ordering. Do not hold thread-owned locks across suspension.
- Exit: supported isolation/transaction contracts and reproducible failures;
  distinguish local durability from export completion.

### V04 — typed application model integration

Depends on V03 isolation findings; R03 and D02/D04/D11/D14.

- Compare small protocol-based mappings with ordinary application models,
  without requiring dynamic-member access or introducing macros first.
- Round-trip identity, optional and supported property types, relationships,
  actions, edits, deletion, and decoding errors.
- Test transfer across actors only for representations with a justified
  `Sendable` contract. Compare live/scoped models and value snapshots as needed.
- Exit: consumer examples and mapping tradeoffs; no final protocol signature
  is required at this stage.

### V05 — native attachments

R04 and D12; local checks first, then the V02 sharing topology.

- Use a dedicated binary attribute with external storage permitted and explicit
  filename/content-type metadata. Compare small and representative large files.
- Test import, read, export, replacement, deletion, rollback, cancellation, and
  backup/restore including externally stored content; never rely on internal
  external-storage paths as public URLs.
- Measure peak memory and latency; verify byte equality or checksums after local
  reopen and real cross-device import, including shared graphs and offline reads.
- Determine which availability/transfer states the stack actually exposes.
  Streaming, selective download, eviction, and per-file progress remain questions.
- Exit: supported lifecycle and measured envelope, not a universal file-size or
  memory guarantee. No direct CKAsset transfer path is assumed.

### V06 — query capability and cost

R05 and D04/D13; use V04 examples when available, with controlled fixtures.

- Evaluate typed filters, relationship predicates, sorting, stable pagination,
  counts, projections, and candidate aggregations.
- Distinguish store execution from explicit in-memory traversal; include cycles,
  bounded depth, unsupported expressions, and incomplete imported structures.
- Measure latency, fetched object counts, and memory across increasing data sets.
  Check result visibility under local writes and remote imports.
- Exit: a capability/cost matrix that identifies feasible operations and limits,
  without promising every candidate query feature.

### V07 — observation and the future of Watch

Depends on V03/V06 and real remote scenarios from V02; D06.

- Compare one-shot queries, updated query results, and streams of changes used
  for processing. Exercise both UI and non-UI consumers independent of the app.
- Verify membership, value, ordering, and deletion updates for local and remote
  changes; include relationships whose changes affect query membership.
- Test slow consumers, buffering/coalescing, cancellation/resubscription,
  duplicate notifications, relaunch, and any proposed replay contract.
- Separate observation of current state from durable event delivery; do not
  infer exactly-once processing or cloud completion from notifications.
- Exit: evidence for keeping, replacing, or splitting Watch. Neither its name
  nor its current callback API is a prerequisite.

### V08 — lifecycle, recovery, and v1 transition feasibility

Consolidates earlier findings; D07–D09/D14.

- Verify opening failures, unavailable account/service, revoked access, recoverable
  retries, explicit reset, backup restoration, and reopening after interruption.
- Test selected v1 data-transition options against the candidate target model,
  distinguishing API adapters, local migration, and cloud continuity.
- Capture recovery outcomes and downgrade limits without making v1 compatibility
  a constraint on the target design.
- Exit: actionable states/errors, explicit destructive boundaries, and supported
  transition options; unresolved cases remain visible in the specification.

## Evidence and specification gate

For each Vxx, retain a short result with question, fixture, environment, procedure,
observations, supporting Apple references, limitations, and design implications.
Link results to the relevant requirement/decision; leave unexecuted items pending.
Use measured results to select performance budgets, rather than inventing them
before representative workloads exist.

Proceed to the specification once the cloud-separation/sharing feasibility is
understood and the chosen foundations have been exercised. Other unanswered
questions may be explicitly deferred with scope and rationale. Do not treat a
successful demo build as completion of this verification roadmap.
