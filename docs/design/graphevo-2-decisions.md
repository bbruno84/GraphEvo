# GraphEvo 2 — decision register

Status: initial specification register, 2026-10-26. This continues D01–D14 from
the [outline](graphevo-2-outline.md); it does not claim all questions are closed.
The [specification](graphevo-2-specification.md) contains working contracts and
the [delivery plan](graphevo-2-delivery-plan.md) identifies when to settle them.

## Maintainer decisions

| ID | Decision | Rationale / effect |
|---|---|---|
| M01 | Target 2.0 directly, using alpha and beta prereleases; keep v1 maintenance separate | Avoid temporary 1.x architectures becoming constraints on the refactor |
| M02 | API compatibility is optional; v1 data migration is mandatory | Public interfaces may change while existing user data has a supported destination |
| M03 | Start implementation using the current schema as a candidate, rather than freezing a new schema first | Test real limits through the new stack and higher-level features |
| M04 | Remain alpha through all eight implementation areas; define schema/API before beta | Query, files, sharing and observation can expose foundational limitations |
| M05 | Use Core Data and NSPersistentCloudKitContainer; expose platform details only where necessary | A custom CloudKit sync engine and app-facing CKRecord/CKAsset handling are not selected |
| M06 | Graphs are separate worlds, including personal cloud graphs; no cross-graph edges | Isolation is a graph membership/sharing requirement, not a claim of one SQLite per graph |
| M07 | Support Swift 6, native asynchronous operations and protocol-based application models | Replace context-bound dynamic-member usage as the primary application integration |
| M08 | Provide native files, improve queries and reassess Watch for all three consumer needs | Feature scope remains library-wide and independent of the current app |
| M09 | Migrate cloud data through a coordinated cutover: v1 stops writing before conversion | Concurrent v1/v2 writing is not required; pending writes, offline old devices and cutover verification still need a supported recovery policy |
| M10 | Keep v1 on `develop`, integrate v2 on `codex/graphevo-2` from the planning branch, and use focused `codex/v2-<topic>` PRs into v2 | Alpha tags come from v2 integration; `release/2.0` starts there at beta, with fixes returning to v2. Stable 2.0 is promoted to `master` and `develop` through reviewed PRs |
| M11 | V2 minimum OS versions may be raised as technically appropriate without inheriting v1 deployment constraints | Choose floors from API/architecture needs and validate their runtime matrix; A1's current iOS 16/macOS 12 declarations are provisional |

M01–M04 and M09–M11 reflect the discussion following the 2026-10-26 laboratory results.
M05–M08 carry forward the initial agreed requirements.

## Technical decisions under development

**Proposed** is an implementation starting point that can change during alpha.
**Open** requires a selected contract; it is not permission to infer a guarantee.
**Direction agreed** fixes a requirement while leaving its mechanism open.

| ID | Status and current direction | Evidence / unresolved part | Settle by |
|---|---|---|---|
| D01 — resource ownership | Partially implemented: one local owner, independently releasable resource leases, coalesced native opening and retained ownership on shutdown failure | [A1](graphevo-2-store-runtime.md) tests local SQLite/in-memory lifecycle and alias rules with current schema. Public logical graph handles, legacy opening exclusion and multi-store/cloud ownership remain pending | A1, reviewed A4 |
| D02 — public isolation | Proposed: transferable value snapshots/IDs and synchronous scoped adapters; no escaping contexts | V03 and accessory V04 compile ordinary Sendable values; ergonomic UI/non-UI models remain to implement | A2/A3 |
| D03 — transaction semantics | Proposed: awaited operation, non-suspending body, per-writer serialization and explicit pre/post-commit cancellation outcomes | V03 shows native perform does not inherit caller cancellation; remote writers remain external | A2, reviewed A5 |
| D04 — values/codecs | Open representation; explicit supported codecs, queryable keys and strict decoding are working contracts | Inventory v1 transformer values; distinguish queryable scalars from opaque encoded payloads | A3, reviewed A7 |
| D05 — shareable unit/topology | Proposed: complete logical graph; runtime private/shared stores and owner-only personal graph shares | V01/V02/V09 positive under stated conditions; actual schema detail rows/cycles/disconnected members untested | A4/A5 |
| D06 — observation | Direction agreed: cover one-shot, observed state and processing needs; proposed separate state and processing contracts | Accessory V07 exposed relationship-dependent invalidation gap; durable replay versus live feed/rescan remains open | A8 |
| D07 — adoption/compatibility | Direction agreed: mandatory data migration, optional source adapter and coordinated cloud cutover | Exact source-version matrix, cutover mechanism and old ID mapping remain open; no requirement for physical in-place reuse | Feasibility A4/A5; design A8; validation beta |
| D08 — platforms/tools | Swift tools/compiler 6.0 required by A1; runtime/tests use mode 6, legacy facade/tests temporarily mode 5. Current OS floors are provisionally iOS 16/macOS 12 and may be raised under M11 | [A1](graphevo-2-store-runtime.md) specifies CI Xcode 16.4; deployment selection follows technical needs, with an explicit runtime matrix and no v1 OS compatibility constraint | Select and verify minimum-toolchain/runtime matrix before beta |
| D09 — availability/recovery | Proposed: explicit local/cloud/access states, no silent substitute for a configured cloud graph | Account switching, permission loss and cached shared-data access policy need dedicated scenarios | A4/A5, consolidated A8 |
| D10 — cloud separation | Direction agreed; owner-only share-zone route is the working candidate | Separate stores did not isolate cloud data; V01 independent recovery and V09 support zones. Selective download/zone scale are not established | A4 |
| D11 — model protocol | Direction agreed; proposed explicit mapping, stable keys and ordinary model values | Exact protocol(s), reference syntax, patch/revision behavior and boilerplate need consumer examples | A3, reviewed A7/A8 |
| D12 — attachments | Direction agreed; proposed dedicated lifecycle over native binary storage | V09 exact cross-account bytes/replacement/deletion; representation, ownership cardinality, memory and offline envelope remain open | A6 |
| D13 — queries | Proposed typed descriptors, explicit Boolean composition, deterministic order and no silent whole-graph fallback | Capability matrix, supported aggregations/traversal and pagination/read-view guarantees remain open | A7 |
| D14 — identity/integrity/conflicts | Proposed graph-scoped durable logical IDs, explicit incomplete structures and no blind transaction replay | V1 IDs incorporate local URI components. V09 disjoint edits converged; same-property conflicts and imported deletion races remain open | Initial A3/A4; consolidated A8 |

The current specification also proposes AND for successive query filters,
caller-owned export destinations, entity deletion cleanup of incident edges,
and separation of handle close from final runtime shutdown. These are technical
defaults for alpha review, not historical v1 behavior or frozen public APIs.

## Cross-cutting choices still open

| ID | Choice | Why it matters | Treatment now |
|---|---|---|---|
| O01 | How is the agreed coordinated cloud cutover established and verified, including pending writes and returning old devices? | M09 removes concurrent v1/v2 writing as a requirement but does not provide a distributed fence | Product choice resolved with the maintainer; technical mechanism remains open |
| O02 | Which minimum OS/toolchain runtime matrix should stable v2 certify? | A1 needs Swift tools 6.0 but retains current OS floors; declared availability is not complete runtime verification | Continue availability review; validate/confirm the supported matrix before beta |
| O03 | Does 2.0 include concurrent app/extension writes to an App Group store? | A process-local owner is insufficient; same-file conflicts were observed in the macOS control | No cross-process safety claim; assess iOS support/cost during alpha |
| O04 | Does processing require durable replay in the first 2.0? | Determines history retention, consumer cursors, acknowledgements and gap recovery | Compare processing examples during A8; do not conflate with state observation |
| O05 | How are empty actions, detached optional edges and incomplete imported structures exposed? | The v1 migration must preserve valid optional forms without legitimizing damaged graphs | Inventory v1 fixtures and define domain invariants during A3/A4 |
| O06 | Which alpha stores need migration to later prereleases? | Early adopters need an explicit data-retention promise before using alphas for real data | Synthetic/disposable until a release explicitly states a supported path |

The only initial maintainer question was the mixed-version policy, resolved
as M09. Other choices remain visible without blocking independent specification
work. Bring a choice back when
evidence narrows its alternatives or its product impact requires direction.

## Decision change discipline

When a proposal becomes an implementation decision, record its rationale,
alternatives, affected contracts, evidence and remaining limitations. Keep
experimental success separate from a supported release guarantee. A schema
change records its v1 migration effect even if alpha files remain disposable.
Do not mark D01–D14 universally closed because one native probe succeeded.
