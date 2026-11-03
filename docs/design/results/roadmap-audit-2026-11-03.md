# GraphEvo 2 roadmap audit — 2026-11-03

## Scope and method

Audited integration: `38f24f6b40d1635b46989f7346a67e2de52b6a7f` (#144).
This is a documentation audit, not new runtime/device acceptance. It compares
the delivery plan and B/R checklist with integrated source, regression suites,
contracts and retained result reports. Historical branch/probe success is not
counted as integrated functionality. Package access is checked in source;
an internal method is not classified as a public application entry point.

The latest retained full checkpoint is
[#41715897139](https://github.com/bbruno84/GraphEvo/actions/runs/41715897139)
on `ae0d50ef688bb0ca5d7088abb12ebfcc0e21f50a`: 993 macOS functions,
990 passed iOS functions with one known skip, and both Swift 6 consumers.
#144's remaining commit changes documentation only. This audit reuses that
evidence without rerunning unchanged suites or claiming a new checkpoint.

## Implementation and evidence map

Paths in this table are repository-relative. Tests establish regression scope;
linked contracts/reports define physical and historical limitations.

| Area | Source and regression anchors | Evidence and actual remaining scope |
|---|---|---|
| Coordinated ownership, transactions and locks | `GraphContextManager.swift`, `GraphCoordinator.swift`, runtime `StoreResources.swift`; `StorePreparedTransactionTests.swift` | [#142 contract](../graphevo-2-controlled-store-access.md), full #387; #144 extends writer ownership across staging. Public opener and current app/widget policy/physical multiprocess acceptance remain open. Cooperating locks do not certify old/direct writers. |
| S04 storage and queries | `GraphTypedStoreAdapter.swift`, `GraphTypedQuerySource.swift`, `GraphTypedQueryExecution.swift`; `GraphDescriptorQueryTests.swift`, `GraphTypedQueryTests.swift` | [P01–P03](../graphevo-2-typed-properties.md), [physical/cost result](s04-typed-properties-runtime-and-cloud-2026-11-02.md), [#143 comparison](descriptor-query-scopes-2026-11-03.md). Native planning and scoped hydration exist; broader device/capacity envelopes remain. |
| Sync transport and lifecycle | `GraphSync.swift`, `GraphCloudSession.swift`, `GraphAutomaticSynchronization.swift`; transport/conflict/pause/automatic-sync suites | [T01](../graphevo-2-record-transport.md), T03–T06 integrated. Durable pending work, effect receipts, conflicts and foreground scheduling exist. Structural conflict scope, account/cache policy, public activation and broader crash/restore evidence remain. |
| Sharing and revocation | `GraphCloudSharing.swift`, `GraphLedgerControlWorker.swift`; sharing and lifecycle suites | [T07 result](zone-sharing-2026-10-31.md), [T08 result](sharing-lifecycle-2026-10-31.md). Bounded two-account sharing/lifecycle evidence exists. Host invitation UI/routing, broader offline/account/interruption/restore acceptance remain. |
| Attachments and spool | `GraphCloudAssetSpool.swift`, `GraphCloudTransfer.swift`; spool/asset/activation suites | [#144 contract](../graphevo-2-durable-asset-spool.md), full checkpoint above. Restart, missing/tampered files, backup and 36 MiB seed are tested synthetically. New-spool physical delivery/interruption and resource envelopes remain open. Permanent bodies remain native; ordinary complex values stay serialized. |
| Observation | `GraphObservation.swift`, `GraphObservationCoordinator.swift`, `GraphObservationPublisher.swift`; observation/Combine suites | [A8](../graphevo-2-observation.md) implements async current state, Combine and live rescan hints. O04 processing/replay policy and current-backend acceptance remain; transport receipts are not a consumer replay API. |
| Protected migration and backup | `GraphMaintenance.swift`, `GraphBackupManager.swift`, `GraphBackupPackage.swift`, `GraphMigrationWorkspace.swift`, `GraphMigrationPublication.swift`, `GraphStoreMigration.swift`; corresponding suites | [MF foundations](../graphevo-2-migration-foundations.md), MF01–MF08 integrated. Internal protected execution and recovery exist. Public consumer orchestration and full restoration/production acceptance remain. |
| V1 opening and cloud bootstrap | `GraphNativeV1Migration.swift`, `GraphContextManager+Activation.swift`; native-v1/activation suites | [MF09](../graphevo-2-local-v1-bootstrap.md), [MF10](../graphevo-2-authoritative-cloud-bootstrap.md), [MF11](../graphevo-2-native-v1-migration.md). Bounded local conversion, staged Core Data route and authoritative seed/empty-peer flow exist internally. Production/historical matrix, public bootstrap, host source completeness and returning-old-client policy remain. |

`GraphContextManager` is declared `package actor`; its coordinated create/open,
session, invitation and cloud bootstrap methods remain package-scoped. Public
typed model/store contracts and historical public openers do not expose that
complete custom-sync flow. This is the main delivery integration gap, not a
missing second engine or migration executor to build alongside the existing one.

## Findings and document corrections

1. The delivery plan still presented much of A1–A8 and the MF foundations as
   future work. Added a current workstream matrix and proposed delivery order;
   explicitly marked the original alpha sequence historical.
2. The development-status M2/M3–M5 summary said protected lifecycle and v1
   conversion were unimplemented. Replaced that with MF01–MF11's bounded
   implementation and remaining public/production gates. Marked old T06 next
   steps historical and corrected the stale post-#143 spool instruction.
3. The checklist conflated missing implementation with broad acceptance. Added
   a current B/R interpretation table and a PA03 supersession note. Retained
   broad gates for unresolved acceptance. Closed only the narrow repeated
   mutation-inventory review already implemented/tested in #142.
4. The controlled-access contract still required future asset-spool adoption.
   Corrected it to #144, preserving physical acceptance as open.
5. The typed-property contract still said P02/P03 were pending. Linked their
   integrated implementation and bounded physical results; broader capacity
   remains open.
6. The migration manager/foundations entry points stopped at M1/M2a or MF07.
   Added the later internal executor, bootstrap and staged-native route without
   promising public activation or production acceptance.

Historical results, source pins, failed runs and old model evidence are retained.
The remaining historical narrative is read under the current matrices rather
than rewritten to claim later capabilities on an older revision.

## Delivery recommendation and unchanged gates

Prioritize physical acceptance of the newest consolidated path, then one public
host integration over the existing coordinator/migration stack. Resolve B
contracts for process topology, account/cache handling, O04, conflict scope and
API/schema support, and review end-to-end migration feasibility before beta.
An application pilot can inform that review; mandatory real-app adoption stays
an R gate. No new requirement for background scheduling, interactive widget
writes or durable consumer replay is selected by this audit.

Beta still requires accepted B gates, not a count of merged PRs. Stable still
requires R acceptance, complete mandatory v1 migration, actual application
adoption, distribution checks and documented recovery. No completion percentage,
release date, tag or release branch is justified by this documentation audit.

## Audit verification

All relative Markdown file targets in the eight changed documents resolve.
`git diff --check` passes. Review confirms documentation-only changes, no
shipping/test/consumer/workflow edits and no broad acceptance gate closed.
No expensive CI label is requested for these notes under the checkpoint policy.
