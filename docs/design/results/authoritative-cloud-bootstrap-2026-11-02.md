# MF10 — authoritative cloud bootstrap, 2026-11-02

Result: the bounded synthetic owner/peer protocol passes on same-account physical
iPad/iPhone, including a rejected independent conversion and a second genuinely
empty replica after ordinary edits. The standalone native first-create exclusion
prerequisite also passes. Implementation remains package-only on the focused
branch pending integration; broader production/historical cutover gates stay open.

## Provenance and isolation

- Contract #139 integrates as `4d6a164`; implementation starts directly from it
  on `codex/v2-authoritative-cloud-activation`, returning to `codex/graphevo-2`.
- Reviewed shipping/test head is `5335079b3be746b31d76a038bae78ab683c66a78`.
  The physical protocol exercises `1adbd8d` production activation.
  Subsequent `5ade87a` and `1e9954e` extend only the external device laboratory;
  shipping Sources, tests, manifest and workflow remain identical through those
  laboratory revisions. Final `5335079` confines ordinary authority lookup to
  private bindings and adds two scope regressions; the physical private-activation
  path is unchanged.
- Native activation format 2 binds physical file identity, native UUID and PH
  epoch. Cloud authority/manifest formats remain 1; session format is 7. S04 and
  primitive/asset formats are unchanged.
- Owner: iPad 10th generation, iPadOS 27.0 (`24A437`). Peer/contender/fresh:
  iPhone 18 Pro, iOS 27.2 (`24B119`). Signed entitlements were inspected:
  `iCloud.com.valerioburiani.GraphCKDemo`, Development only.
- Account equality was checked privately using run-salted hashes. Account values,
  digests, native stores, local receipts/maps, signing, run envelopes and raw device
  reports remain external. No private support archive was read or uploaded.
- Fresh random laboratory zones and distinct source/target stores are used.
  No container reset, source mutation, copied fresh replica or consumed-stage
  replay occurred. Planned restarts terminated only acknowledged host PIDs.

## Native prerequisite and retained prototype evidence

The standalone [claim probe](../../../Experiments/AuthoritativeCloudProbe/README.md)
exports the integrated `4d6a164` runtime and overlays the claim controller retained
in `c61e1c1`. Two independent untagged records target the same fixed record ID
under `ifServerRecordUnchanged`. Exactly one save succeeds; the other returns
serverRecordChanged. A subsequent untagged contender is also rejected, preserving
the actual winner and its nonempty server change tag. Its synthetic zone remains.
This proves the selected native exclusion behavior, not a distributed v1 fence.

An initial device-host compile found a scope adapter/GraphID parameter mismatch
in the external bridge. It was corrected before any activation fixture invocation.
Three owner stages then pass on `197fe73`, with prototype native format 1. Those
reports/stores are retained unchanged; they do not establish format-2 acceptance.
Review found that a copied file could retain UUID/PH metadata, so format 2 adds
physical identity and refuses prototype format 1 rather than migrating it.

## Format-2 physical protocol

All twelve reports below pass. Preparation pins `1adbd8d`; account checks,
owner seeding/publication, first peer recovery and ordinary owner edit use the
`5ade87a` laboratory over identical shipping code. The later iPhone bridge is
`1e9954e` over the same exported runtime and adds the explicit `later == 2`
assertion for refresh/fresh recovery. The independent owner verification retains
its original `5ade87a` bridge pin. No stage is rerun after a bridge update.

| Stage / replica | Observed evidence |
| --- | --- |
| prepare / owner | Five synthetic v1 primitives are converted with verified backup; a separate 2-MiB attachment yields six seed records. Native preparation blocks writes and retains the source SQLite digest. |
| verify-account / owner | Read-only private account comparison evidence, without graph/cloud mutation. |
| verify-account / peer | Same salted result privately confirms the owner's account before private-zone recovery. |
| seed / owner | Process restart restores write admission; production PH/transport sends the six-record seed and remains in seeding phase. |
| publish / owner | A further process restart retains authority and acknowledges the empty queue; complete server payload/topology/asset verification precedes publication. |
| recover-peer / peer | A genuinely empty independent native store recovers all six UUIDs, complete values/topology and attachment bytes. Full integrity passes and outgoing work is empty while the iPad owner remains alive. |
| update-owner / owner | Ordinary post-publication `later = 2` editing and real send succeed. Complete local/server inventories agree while the peer remains alive. |
| refresh-peer / peer | Reopen fetch/import observes explicit `later == 2`; complete local/server equality, integrity and no upload feedback pass. |
| prepare / contender | A distinct local conversion creates a separate random UUID mapping and operation for the same GraphID/zone. Its original source remains retained. |
| seed / contender | Authority conflict is returned before binding/sending the competing seed; local conflict state is durable. |
| verify / owner | The original authority, source digest and exact six-record current server/local inventory survive the contender unchanged. |
| recover-peer / fresh | Another genuinely empty store recovers the updated current state, explicitly including `later == 2`, topology and the 2-MiB asset, with zero upload work. Owner remains alive. |

The initial seed digest is historical after publication; later peer recovery
validates the current cloud graph, preserving original logical identities rather
than requiring stale seed values. Neither publication nor empty local queues are
a certificate of future global convergence.

## Local checks and review corrections

The complete macOS profile passes **947 functions** on `5335079`: 331 legacy,
508 store, 78 runtime and 30 model. Focused iOS 18.5 Simulator checks pass
**109 functions / 117 invocations**, zero failures/skips, covering activation,
bootstrap, session, transport, sharing, foreground scheduling and runtime admission.
All three independent package/model/process consumers pass; manifest and diff
validation pass. No unchanged-library suite is repeated for the final prose.

Deterministic coverage includes separate conversions, foreign/prepopulated zones,
same-operation restart, ambiguous claim/publication success, partial upload,
offline/cancelled preparation, immutable-seed/binary bounds, native receipt
corruption, physical-copy refusal and same-volume relocation. Runtime tests prove
alias coverage, generation-bound release, independent resources and preservation
of other maintenance/sharing restrictions. Core Data external-reference clone
diagnostics emitted by synthetic large-property fixtures remain in the raw local
logs; test assertions and backup/source checks pass.

Review closes four concrete gaps: converted stores could bypass preparation via
ordinary binding; native UUID/PH identity alone admitted physical copies; and a
foreground worker could become blocked by trying ordinary work during seeding;
and ordinary shared binding must not consult private activation control.
Binding/transport/invitation admission now rejects bypasses, the native marker
checks the receipt and physical file, and pending activation routes suspend
foreground application work/fetch until publication. A virtual-clock production
worker regression proves normal progress afterward without clearing failures.

## Remaining gates

Remote full CI is not requested yet. Under the checkpoint policy, the reviewed
runtime/shared-foundation increment requires one `ci-full-checkpoint` immediately
before an authorized merge. Earlier #365 remains historical evidence, not this
increment's remote validation. No skipped job is counted as a passing checkpoint.

The bounded MF10 protocol does not establish source completeness across real v1
cloud stores, cessation of old writers, returning-client policy, historical codec
coverage, large production workloads, hard-power-loss behavior or production
CloudKit schema deployment. Consumer-controlled binary transformation, public
bootstrap, authority transfer/restored-backup activation and initial sharing are
separate work. Source data/backups and failed/partial remote authority are retained;
there is no automatic cleanup, takeover or release/tag request.
