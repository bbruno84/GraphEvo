# Durable CKAsset spool — physical checkpoint, 2026-11-04

Status: protocol and evidence integrate through
[PR #146](https://github.com/bbruno84/GraphEvo/pull/146). Reviewed
[full checkpoint #41782215684](https://github.com/bbruno84/GraphEvo/actions/runs/41782215684)
passes on `db80d8cdf0011d990dba1be6f6281345fbc2c8b8`: 993 macOS functions,
990 passed iOS functions with one known skip, and both Swift 6 consumers.
Final integration notes change documentation only; shipping, bridge/helper,
test, consumer and workflow inputs match the reviewed head.

## Outcome and scope

The private S04 custom-sync path recovered four 10 MiB attachments, an empty
attachment, serialized array/dictionary/Codable properties and an independent
512-byte attachment control on physical same-account iPad/iPhone replicas.
Outgoing preparation and incoming staging survived application-process restart.
Full local/server record comparisons, actual CKAssets, byte counts, digests,
ownership and empty fixture queues were checked. Consumed transport files were
retired; unrelated database-zone lifecycle events were preserved.

There are eight passed reports and one retained failed report. The latter was
an overbroad global-session assertion in the probe after successful import;
the bounded read-only continuation below verifies the already persisted data
without replaying the failed stage. This is not an all-green nine-stage run.

No shipping runtime change was required. This closes only the bounded private
spool checkpoint selected after #144. It does not close broad beta acceptance,
cross-account sharing, MF10 authority/conversion, arbitrary media, production
resource limits or interruption during native/file publication or power loss.

## Provenance

- Integrated shipping baseline: #145, `5d119745321e18698aa7d379a65f7a7195177c51`.
  Its Sources/manifest/tests/consumer/workflow inputs match the #144 checkpoint.
- Initial signed host exports committed `0fc16a3`; bridge/helper development is
  confined to `Experiments/CloudSpoolProbe`. The initial phases and original
  failed `apply-peer` use this host. Launch/collection helpers at `1799e7d`
  select the existing provisioned laboratory app.
- Corrected signed host exports `25ef3d2a`; changes are solely fixture-zone
  queue assertions and the guarded read-only continuation. It runs the three
  final phases. Shipping Sources are identical across both exports and baseline.
- Devices: iPad (10th generation), iPadOS 27.0 / `24A437`; iPhone 18 Pro,
  iOS 27.2 / `24B119`. Both account preflights passed; salted digests were
  compared privately before the first graph mutation.
- Xcode 27.2 (`27B52`), Swift 6.4.2. Signed app entitlements were checked for
  the sole retained laboratory CloudKit container and Development environment.

The new [probe protocol](../../../Experiments/CloudSpoolProbe/README.md) exports
the committed library into a disposable signed demo. The user's demo checkout
and its existing local changes are untouched. Existing app data and previous
zones are retained. Account values, run identities, archives, stores, logs,
signing settings and body bytes remain outside Git. Stage/report and launch
acknowledgements are independent; both planned restart pairs have different
acknowledged process IDs.

## Observed sequence

| Phase | Result and bounded observation |
|---|---|
| `account` / owner and peer | Two passed read-only preflights; same-account equality checked privately. |
| `prepare-owner` | Passed. Main graph has one owner plus five attachment nodes: four 10 MiB files and an empty file. Separate control has owner plus 512-byte attachment. The first attempt retains 30 MiB as owned files before any main-graph send; encoded frozen attempt is 24,335 bytes. |
| `resume-owner` | Passed after terminating the acknowledged prepare process. Frozen attempt and file hashes equal the retained proof. All 40 MiB publish across bounded windows. Full local/server inventories agree with actual CKAssets and nonempty native tags. Outgoing files are retired after durable receipts; writer remains live for peer observation. |
| `fetch-peer` | Passed on genuinely empty independent stores. Eight application records and six attachment references are retained, alongside unrelated zone lifecycle events. Inbox archive is 78,129 bytes; session archive is checked below 256 KiB. Referenced content totals 41,943,552 bytes (40 MiB + 512), including the empty file. Local application stores remain empty. |
| `apply-peer` | Failed only at the original final global-inbox assertion. Restart proof, application and full data/server verification precede that assertion. Retained session inspection finds 65 remaining `zoneChanged` events and zero asset references. No phase replay occurs. |
| `verify-applied-peer` | Passed on the corrected host. Guard requires the original failed report; it opens the same stores, performs no fetch/import, verifies complete already-imported data and server agreement, and checks empty fixture inbox/spool while retaining unrelated zone events. |
| `verify-owner` | Passed after independent peer verification. Original owner reopens, fetches/applies, checks full local/server state, unchanged control, no outgoing feedback and no retained outgoing body files. |
| `recover-fresh` | Passed while owner remains live. Another genuinely empty replica on the independent iPhone recovers all original IDs/content/complex properties/control from CloudKit, with no copied store, duplicate application nodes, upload feedback or retained incoming files. |

The main graph's permanent body content remains in Core Data. Ordinary complex
properties retain serialized payload values. The 32 MiB limit is an outgoing
work window, not a database or first-replica size cap. No oversized individual
attachment or relaxed budget is used.

## Retained setup and probe corrections

The initial host build at `572ddc2` failed because `.typedProperties` was resolved
against `StoreSchema`; `0fc16a3` explicitly selects
`GraphRuntimeSchema.typedProperties`. No device stage ran on the failed build.
An alternate app bundle could not be provisioned with available local signing
credentials/profile. The maintainer authorized replacing the existing laboratory
host; old app data and stores were preserved. Both actual signed host builds pass.

The first probe checked `cloudStatus.inboxCount == 0` after applying its two
bound zones. CKSyncEngine also reports database lifecycle events for retained
old laboratory zones. GraphEvo correctly preserved those events; the diagnostic
session had 65 `zoneChanged` entries and no asset references. The corrected
probe checks only its bound zones and still requires empty asset files, no
session failure and no pending outgoing receipts. It never deletes other zone
events to satisfy an assertion. Original failing evidence remains retained.
The supported graph/zone scale and retention policy must account for unbound lifecycle events; this fixture does
not establish an unlimited retention envelope.

## Verification and remaining gates

Local validation includes both signed physical builds, launch/report identity
checks, exact persisted proof comparisons, scoped local/server inventories,
Python helper syntax/help, Markdown targets and `git diff --check`. Ordinary
package builds do not compile the external bridge; remote package CI cannot
substitute for this signed-device evidence.

Both restarts occur at verified durable checkpoints: before send and before
import. They do not demonstrate process death in a write/save/send callback,
filesystem power-loss atomicity, quota/disk exhaustion, cross-account permission
changes, joint backup restoration or production performance. MF10's larger
authoritative seed has separate synthetic evidence and is not exercised here.
The roadmap's next implementation recommendation remains the public coordinated
opening/migration/cloud host flow; broader B/R acceptance retains its scope.
