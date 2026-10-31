# T04 — real CKAsset transport, 2026-10-31

Result: **ten successful logical stages**, following two retained failed stages
and explicit guarded continuations. Complete file transfer, async empty recovery,
whole-attachment conflicts under both policies, reopen, cascade and final empty
replica recovery pass on same-account iPad/iPhone. No source mutation was replayed.

## Provenance and chronology

- Branch `codex/v2-cloud-assets` directly from integrated #115 (`8d88532`).
- Initial code runtime `cf7056b5009a363a353098309ac34d03c348ad71` passed the local
  suites and initial physical transfer/recovery cases. A signed disposable demo
  adds only the [external bridge](../../../Experiments/CloudAssetProbe/README.md).
- Entitlements checked: `iCloud.com.valerioburiani.GraphCKDemo`, Development.
  One fresh GE2-T04 run, private A/C/B zones and separate stores for owner/peer/
  fresh replicas. No reset, purge, old-file migration or store copying.
- Owner: iPad10 / iPadOS27.0. Peer and later fresh replica: iPhone18 Pro / iOS27.2.
  Account values compared privately and matched; bindings remain graphID + zone.
- Initial seed failed in bridge code after A had successfully published its
  10MiB and empty files. The bridge unnecessarily constructed A's empty-file ID
  with C's owner, correctly rejected as invalidMetadata. Runtime code was unchanged.
  The reserved seed was not replayed. `seed-remaining` required A3/C0/B0 local rows,
  skipped A, seeded only C/B and verified full exact server/local inventories.
- Empty peer recovery, peer preparation and owner replacement then passed on
  cf7056b. Native asset conflict resolution failed with invalidState before any
  sent receipt was retained; the immutable attempts and inbox remained durable.
- Apple documents that serverRecordChanged's serverRecord has nil fileURL for
  every asset. The corrected runtime `834e67493a9aacaa146a574d8eb6ac9ae3180d9f`
  asynchronously fetches complete current server content before receipt conversion.
  A concurrent unknownItem follows delete-wins; other lookup errors preserve work.
  This is production code correction, not a probe that bypasses asset validation.
- `resolve-remaining` reopened the same original stores/session, required both
  attempts to equal their original Frozen-A/C artifacts and one pending change
  each, then retried only the frozen transport intent. It did not rerun consumer
  replacements. All remaining six stages passed on 834e674.

The ten passed stage reports consist of four on cf7056b (including seed-remaining)
and six on 834e674 (including resolve-remaining). The two original failed reports,
launch/scene tickets, runtime exports, signed builds, stores/zones and private
session inspection remain retained externally. No failed stage was relaunched or
its report replaced. Owners stayed alive through independent observations.

## Confirmed behavior

| Case | Observed result |
|---|---|
| Initial assets | Actual GraphEvoNode asset fields are CKAssets. Empty,512-byte and10MiB content matches full local/server records, ownership, digest, dates and real change tags. |
| Empty peer async delivery | Package-only async export recovers complete files into caller-owned destinations from genuinely empty stores. PH upload queues remain empty. |
| Concurrent replacements | Peer freezes4096-byte/date300 revisions, owner subsequently publishes2048-byte/date200 revisions. A lastEditWins ends with peer4096; C cloudWins ends with owner2048. Metadata, revision and bytes remain one complete logical value. |
| Conflict recovery | Original pending attempts survive the pre-receipt failure and restart. Corrected complete-server lookup resolves both conflicts; no manual metadata reset or consumer-body replay. |
| Independent owner observation | Complete A/C/B inventories agree with server; B remains512 bytes and A's empty file remains unchanged. No feedback upload. |
| Peer reopen | Without fetching, resolved files/policies and empty queues persist across process/session restart. |
| Owner cascade | Deleting A's owner produces three acknowledged deletions: owner, primary file and empty file. C/B remain unchanged. |
| Peer/fresh final recovery | A contains zero application records; C/B recover exact complete records/content. Full local/server inventories and empty queues agree, without resurrecting deleted files. |

Verification enumerates all scoped logical IDs and all server zone modifications
from nil tokens (limit100; moreComing refused), compares full GraphRecords and
expected bytes/owners/date, and requires real nonempty native tags. There is no
SQL-file inference of synchronization. Controlled injected edit clocks establish
ordering only; server tags and CKAsset transport are actual framework outcomes.

## Local verification and bounded scope

Corrected full local macOS suite passes **679 functions**:331 legacy,254 store,
71 runtime,23 model. Selected iOS18.5 suites pass63 functions/90 expanded cases.
New deterministic tests additionally cover caller cancellation/deadline isolation,
shared refresh and independent writes during a paused fetch, corrupt asset rollback,
legacy/split preservation, edge ownership ordering, disappearance of SDK staging,
both policies and full-conflict refetch route/error validation. ModelConsumer,
manifest and diff checks pass. Final exact-head CI disposition belongs to the PR.

This is small private-data evidence, not a supported production resource envelope,
shared-account permission test, EDGE/background latency test, disk-pressure cleanup
or crash/backup certificate. Duplicate durable content and extra per-conflict
fetch cost require measurement. The 10MiB/file and32MiB encoded state ceilings are
unchanged. Production CloudKit deployment of the optional asset field, broader
sharing/account/offline/interruption and mandatory v1 conversion remain open.

Reference: [Apple CKAsset.fileURL](https://developer.apple.com/documentation/cloudkit/ckasset/fileurl?language=objc)
explicitly describes the missing download in conflict records.


Final review also centralizes frozen/inbox archive restoration and refuses any
SDK CKAsset/path before decoding, including an outgoing provider request. This
regression is covered deterministically; the physical run remains explicitly
pinned to834e674 and is not relabeled as later-code device evidence.

Final restoration-hardening validation passes **680 functions** (331 legacy,
255 store, 71 runtime, 23 model), selected iOS18.5 passes64 functions/91 expanded
cases, and ModelConsumer/manifest/diff checks pass. Final CI is recorded in PR116.
