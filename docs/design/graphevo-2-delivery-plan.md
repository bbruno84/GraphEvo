# GraphEvo 2 — delivery plan

Status: initial plan, 2026-10-26. Read with the
[specification](graphevo-2-specification.md) and
[decision register](graphevo-2-decisions.md).

## Release policy

Develop directly toward 2.0 through alpha and beta releases. Keep v1 fixes on
the v1 integration/maintenance line. Use the existing `codex/graphevo-2-design`
branch as the planning parent; implementation work uses focused child branches
and reviewed changes. The permanent v2 integration branch name and package
distribution arrangement are implementation setup decisions, not new shared
branches created by this document. Do not mix v2 breaking work into routine v1
releases or merge the planning PR as an implicit implementation release.

Each alpha is a coherent usable increment with its model/API revision and
known limits recorded. Alpha stage numbers below are planning milestones,
not a promise of one prerelease tag per stage. Remain alpha through stage 8.

## Alpha sequence

| Stage | Work and dependencies | Demonstrable exit | Relevant checks |
|---|---|---|---|
| A1 — resource ownership and lifecycle | Build the new runtime, store identity/registry, awaited open/close and private context ownership, using the current schema as first candidate and Swift 6 from the outset | Two compatible handles share resources safely, independent resources remain independent, handle release does not invalidate another handle, and shutdown/reopen work | V03, V08; S4 |
| A2 — async operations and transactions | Complete safe value reads, isolated mutation scopes, serialized writes, errors and cancellation on A1 | A non-UI Swift 6 consumer reads/writes without context escape; rollback, cancellation and admitted-work shutdown have tested outcomes | V03; S4–S5 |
| A3 — application models | Implement protocol-based typed mapping for Entity, Relationship and Action, identity/references, tags/groups and explicit edits | A small independent consumer creates, reads, edits and deletes a typed graph without dynamic-member access; decoding and scope errors are visible | V04, V03; S3, S6 |
| A4 — graph separation and mirroring | Apply the candidate membership model to the new runtime, private/shared topology and personal graph share boundaries; revise schema only where required | Two personal graphs retain separate cloud boundaries on an independent replica, including detail rows and mutations; local readiness/import integrity stay distinct | V01, V02.12, V03.8; S3, S7 |
| A5 — user sharing | Add invitation/acceptance, owner/participant writes, permissions, leave/revocation and recovery on A4 | Different-account devices recover and mutate one complete graph without leaking the control graph; partial native operations are diagnosed/recoverable | V02; S5, S7 |
| A6 — files | Implement attachment ownership, metadata, import/read/replace/delete/export and whole-content backup with A4/A5 | Exact binary lifecycle and cross-account recovery with a measured memory/size envelope; no internal file paths exposed | V05; S8 |
| A7 — queries | Build typed query composition, related-node filters, count/projections, deterministic ordering and selected pagination/aggregations | Capability/cost matrix and representative queries with explicit unsupported cases and bounded traversal | V06; S9 |
| A8 — observation | Compare/implement one-shot results, observed state and processing needs on A7 and real mirroring | Correct dependency invalidation, local/remote refresh, cancellation, slow-consumer behavior and an explicit live/replay contract; then reconcile schema/API and meet the beta gate | V07; S10–S12 |

S references refer to numbered sections of the specification. A1 is the next
implementation milestone; it does not require a predesigned frozen v2 schema.
A1/A2 are two increments of the same stack foundation, not independent runtime
architectures. A3 needs an initial identity/mapping proposal, not a premature
commitment to its final storage representation. Schema changes retain their
rationale and test fixtures so higher-level features can challenge earlier choices.

## Migration throughout alpha

Migration is a parallel workstream rather than a task first discovered after
A8:

- A1: preserve source-version definitions and synthetic populated v1 fixtures;
  inventory source properties/codecs/identity and current backup behavior.
- A2/A3: demonstrate that every v1 concept has a destination or retained opaque
  representation, and exercise old-to-new reference mapping on copies.
- A4/A5: select and prototype the old-cloud-layout transition, replica recovery,
  duplicate prevention and the coordinated cutover with v1 writes stopped.
  Define pending-write/returning-old-device recovery. Resolve any schema
  limitation that would make mandatory migration infeasible.
- A6: include externally stored bytes and attachment metadata in transformation
  and recovery fixtures; ordinary v1 binary properties are not assumed to be
  dedicated v2 attachments without an explicit interpretation.
- A7/A8: use migrated fixtures to exercise queries/observation and classify
  legacy history/ledger state that is preserved, translated or superseded.
- A8: review end-to-end migration feasibility and interruption/recovery protocol.
  Final implementation and broad real-store validation continue during beta.

Alpha release notes explicitly state whether a prior alpha store is reusable,
migratable or disposable. Experimental alpha files do not silently replace v1
production data. Full automatic migration from every alpha is not an agreed
requirement; settle the supported alpha-to-beta path before external adoption.

## Beta entry gate

Enter beta only when:

1. All eight areas have been implemented or have a precise agreed scope. An
   accepted deferral states its user impact; a vague unchecked item is not a
   completed feature.
2. The target persistent schema, identity/reference rules and supported typed
   API are defined, with decisions justified by integrated behavior.
3. Cloud membership/sharing uses supported public APIs and has real-device
   evidence with the selected model, not only the V09 surrogate.
4. Transaction, cancellation, read/conflict, permission, incomplete-import and
   observation-delivery contracts are explicit and tested for supported uses.
5. The v1 local/cloud migration design is feasible on representative fixtures,
   including identity translation, source protection and recovery. Its remaining
   implementation/validation work is enumerated; migration is not deferred past
   the final release.
6. Supported OS/toolchain, process topology, query capabilities, attachment
   envelope and recovery limitations are published.

## Beta and final release

During beta, complete migration tooling and validate copies of representative
application stores, then integrate the real application. Exercise interruption,
failed conversion, retries, duplicate prevention and recovery on an independent
cloud replica. Validate ordinary local/cloud lifecycle and performance on the
supported OS matrix. Keep small independent consumers in addition to the app.

Schema and API are consolidated at beta entry. An incompatible beta correction
requires a specific rationale, revision notes and a supported migration for
affected adopted beta data; it is not an ordinary unannounced change.

Release 2.0 only after mandatory v1 migration, real app adoption and the selected
library acceptance matrix pass, with documented recovery/downgrade boundaries.
Review any optional v1 API adapter separately; it cannot block or weaken the
core design. Documentation and examples move to the actual v2 contracts while
v1 guidance remains accessible.
