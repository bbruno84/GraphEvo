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
| M12 | Keep A6's attachment identity/ownership approach and assess representation costs at alpha completion | The maintainer accepted the model; defer file-cost redesign while completing queries/observation, then consolidate schema/API before beta |
| M13 | Incompatible alpha layouts start from empty stores; no alpha-to-alpha conversion, downgrade or interrupted alpha-conversion recovery | Remove alpha conversion tooling from adoption gates; reject existing incompatible paths without automatic erasure. Mandatory v1 migration and beta compatibility remain separate |

M13 records the 2026-10-29 fresh-store decision.

M01–M04 and M09–M11 reflect the discussion following the 2026-10-26 laboratory results.
M05–M08 carry forward the initial agreed requirements. M12 records the
2026-10-27 attachment discussion and cost-review timing.

## Technical decisions under development

**Proposed** is an implementation starting point that can change during alpha.
**Open** requires a selected contract; it is not permission to infer a guarantee.
**Direction agreed** fixes a requirement while leaving its mechanism open.

| ID | Status and current direction | Evidence / unresolved part | Settle by |
|---|---|---|---|
| D01 — resource ownership | Partially implemented: one local owner, independently releasable resource leases, coalesced native opening and retained ownership on shutdown failure | [A1](graphevo-2-store-runtime.md) tests local SQLite/in-memory lifecycle and alias rules with current schema. A3 adds local public logical handles and legacy gateway exclusion; A5 adds paired resource claims, partial-load cleanup and retained quarantine | A1, reviewed A4 |
| D02 — public isolation | Proposed: transferable value snapshots/IDs and synchronous scoped adapters; no escaping contexts | [A3 typed scopes](graphevo-2-typed-store.md) return Sendable models, invalidate non-Sendable scopes and exercise UI/non-UI consumers; cloud isolation remains later work | A2/A3 |
| D03 — transaction semantics | Proposed: awaited operation, non-suspending body, per-writer serialization and explicit pre/post-commit cancellation outcomes | V03 shows native perform does not inherit caller cancellation; remote writers remain external | A2, reviewed A5 |
| D04 — values/codecs | First detached GraphValue candidate; native null/UUID/encoded integration remains open; explicit supported codecs, queryable keys and strict decoding are working contracts | The plain bridge rejects ambiguous NSNull; A3 typed properties use a versioned envelope for explicit null/UUID/opaque values. Inventory remaining v1 values and settle lossless storage; distinguish queryable scalars from opaque payloads | A3, reviewed A7 |
| D05 — shareable unit/topology | Owner-private candidate implemented: complete logical graph and owner-only personal graph shares; A5 adds paired topology and participant operations | V01/V02/V09 positive under stated conditions; A4 implements hidden membership without a native schema change and tests actual detail rows/cycles/disconnected owner-private members. A5 implements resource ownership/participant routing and local intent recovery without assignment replay; broader crash/conflict combinations remain open | A4/A5 |
| D06 — observation | A8 alpha implements newest-state async observation and a demand-aware Combine adapter; processing currently uses bounded live rescan hints | [A8 contract](graphevo-2-observation.md) conservatively invalidates the whole resource group, including related/action/file dependencies; durable replay remains O04 and production costs remain consolidation work | A8 / beta consolidation |
| D07 — adoption/compatibility | Direction agreed: mandatory data migration, optional source adapter and coordinated cloud cutover | Exact source-version matrix, cutover mechanism and old ID mapping remain open; no requirement for physical in-place reuse | Feasibility A4/A5; design A8; validation beta |
| D08 — platforms/tools | Swift tools/compiler 6.0 required by A1; runtime/tests use mode 6, legacy facade/tests temporarily mode 5. A2 raises macOS to 13 for its native cancellation signal; current OS floors are provisionally iOS 16/macOS 13 and may be raised under M11 | [A1](graphevo-2-store-runtime.md) specifies CI Xcode 16.4; deployment selection follows technical needs, with an explicit runtime matrix and no v1 OS compatibility constraint | Select and verify minimum-toolchain/runtime matrix before beta |
| D09 — availability/recovery | Proposed: explicit local/cloud/access states, no silent substitute for a configured cloud graph | Account switching, permission loss and cached shared-data access policy need dedicated scenarios | A4/A5, consolidated A8 |
| D10 — cloud separation | Direction agreed; owner-only share-zone route is the working candidate | Separate stores did not isolate cloud data; V01 independent recovery and V09 support zones. Selective download/zone scale are not established | A4 |
| D11 — model protocol | First candidate implemented: GraphModel/GraphPropertyValue, detached records, explicit keys and partial patches | [A3 contracts](graphevo-2-application-models.md) have public Swift 6 consumer and package SQLite tests; typed public CRUD and persisted local IDs are implemented in the [continuation](graphevo-2-typed-store.md); remaining legacy codecs and remote identity still need validation | A3, reviewed A7/A8 |
| D12 — attachments | A6 alpha candidate: dedicated owned lifecycle over one native transformable content value | A6 selects exclusive same-graph ownership, unchanged native model, a 10-MiB buffered limit and closed whole-directory copies. V09 remains separate surrogate evidence; account/cache, larger-file and conflict envelopes remain release work | A6 |
| D13 — queries | A7 alpha typed descriptors with explicit bounded inventory/memory strategy, Boolean composition and deterministic order | [A7 candidate](graphevo-2-queries.md) supplies an explicit bounded strategy, scalar capability matrix, related predicates/BFS, projections/aggregations and moving cursors; indexing/production envelopes remain consolidation work | A7 |
| D14 — identity/integrity/conflicts | Proposed graph-scoped durable logical IDs, explicit incomplete structures and no blind transaction replay | A3 stores graph/node UUIDs in reserved detail rows and maps old facade IDs during backed-up local adoption. Replica recovery is unverified. V09 disjoint edits converged; same-property conflicts and imported deletion races remain open | Initial A3/A4; consolidated A8 |

The current specification also proposes AND for successive query filters,
caller-owned export destinations, entity deletion cleanup of incident edges,
and separation of handle close from final runtime shutdown. These are technical
defaults for alpha review, not historical v1 behavior or frozen public APIs.

The [C01 cost review](results/c01-cost-baseline-2026-10-27.md) is evidence for
D01/D12/D13 and observation execution costs, not a new maintainer decision or
schema freeze. It supports prototyping selective identity/session access,
separate attachment metadata/body and shared observation work under the
[consolidation plan](graphevo-2-consolidation.md). M12's final representation/
envelope decision remains open after this first local screen.

## Cross-cutting choices still open

| ID | Choice | Why it matters | Treatment now |
|---|---|---|---|
| O01 | How is the agreed coordinated cloud cutover established and verified, including pending writes and returning old devices? | M09 removes concurrent v1/v2 writing as a requirement but does not provide a distributed fence | Product choice resolved with the maintainer; technical mechanism remains open |
| O02 | Which minimum OS/toolchain runtime matrix should stable v2 certify? | A1 needs Swift tools 6.0 but retains current OS floors; declared availability is not complete runtime verification | Continue availability review; validate/confirm the supported matrix before beta |
| O03 | Which app/widget read/write roles and synchronization owner are supported on the same App Group graph? | Maintainer requires concurrent app/widget access before beta (2026-10-29); process-local ownership is insufficient. Read-only widget access is a candidate, while interactive writes remain a scope decision | Design, implement and validate iOS multiprocess behavior before beta under PA02; no current cross-process safety claim |
| O04 | Does processing require durable replay in the first 2.0? | Determines history retention, consumer cursors, acknowledgements and gap recovery | A8 supplies live invalidation plus explicit rescan as its alpha candidate; select stable scope during consolidation and do not conflate it with durable processing |
| O05 | How are empty actions, detached optional edges and incomplete imported structures exposed? | The v1 migration must preserve valid optional forms without legitimizing damaged graphs | Inventory v1 fixtures and define domain invariants during A3/A4 |
| O06 | Resolved by M13: no migration between incompatible alpha stores | Alphas start from empty stores; do not use them with a data-retention promise | Remove alpha conversion tooling from adoption gates; preserve v1 migration and beta rules |

The only initial maintainer question was the mixed-version policy, resolved
as M09. Other choices remain visible without blocking independent specification
work. Bring a choice back when
evidence narrows its alternatives or its product impact requires direction.

## Decision change discipline

The [post-alpha checklist](graphevo-2-post-alpha-checklist.md) tracks closure
of cross-cutting decisions and their release validation, including M12
attachment costs. Keep it aligned when resolving D01–D14 or O01–O06.

When a proposal becomes an implementation decision, record its rationale,
alternatives, affected contracts, evidence and remaining limitations. Keep
experimental success separate from a supported release guarantee. A schema
change records its v1 migration effect even if alpha files remain disposable.
Do not mark D01–D14 universally closed because one native probe succeeded.
