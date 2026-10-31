# T01 — real private record transport, 2026-10-31

Result: **ten ordered stages passed** with the integrated manual record
transport on iPad and iPhone using the same iCloud account. Exact values,
primitive topology, deletion effects, control graph, server change tags,
reopen and empty-replica recovery were checked. This is bounded private
transport evidence, not beta acceptance or general synchronization completion.

## Provenance and isolation

- Runtime: reviewed/merged [#111](https://github.com/bbruno84/GraphEvo/pull/111),
  merge `06b5ae5ebce6cc6635d3092cb9bd4346ffc57d1b`; merge tree equals reviewed
  head `5d588ea7780185c2e5aee75db026d6d9a3548bda`.
- Exact-head macOS/iOS CI: `41190746167` green. The preceding
  `41189893048` had an unexpected store-test process exit; no runtime fix is
  claimed. Local iOS 18.5 store validation passed 222 functions / 262 expanded
  cases, and the next remote run passed. Explicit iOS xcresult retention was
  added so a recurrence can be diagnosed. Keep crash/stress follow-up open.
- Host: disposable copy of the configured demo; the preparation script exports
  the pinned committed runtime tree and adds only the external laboratory bridge
  to its GraphEvo module. No CS01 prototype engine is used. The production
  package manifest/API and the original demo checkout remain unchanged.
- Built app signing was inspected: only authorized test container
  `iCloud.com.valerioburiani.GraphCKDemo`, CloudKit service, **Development**.
  No container reset, schema deletion, old fixture conversion or zone purge.
- Hardware: iPad (10th generation), iPadOS 27.0; iPhone 18 Pro, iOS 27.2.
  Native session account values were compared privately and matched. No account
  identity, invitation, native store or engine serialization is committed.
- A fresh run UUID defines new private A/B zones. Owner, peer and final fresh
  replica use distinct app-relative directories. Native stores were created
  through exclusive coordinators; no source-store copy populated a replica.
  The engine document on both devices is format 2; persisted bindings have
  only graph and scoped zone identity, with no file URLs.

Protocol and executable assertions:
[RecordTransportProbe](../../../Experiments/RecordTransportProbe/README.md).
The laboratory bridge is outside normal package source paths and is compiled
only into the disposable host's library copy.

## Results

| Ordered stage | Device / replica | Result |
|---|---|---|
| `seed` | iPad / owner | A contains two entities, one directed relationship and one action; B contains one control entity. Actual engine sends complete. Direct CloudKit reads compare exact CF01 GraphRecords and nonempty native server tags. Pending upload work is empty. |
| `read-baseline` | iPhone / peer | Genuinely empty stores recover all primitives and exact values/topology through the native engine and retained inbox. B is correct; imports generate no upload work. |
| `update` | iPad / owner, original files reopened | Change an entity value, remove a property, add a tag, insert a third entity and new edge, and extend action subjects. The frozen outgoing archive reuses the change tag independently read from the server. Exact local/server results pass; B unchanged. |
| `read-update` | iPhone / existing peer | All updated values, new objects and references recovered. No upload feedback; B unchanged. |
| `delete` | iPad / owner | Delete the original target entity. Its original directed edge disappears; the action survives with reduced endpoints; the new entity/edge survive. Direct server reads confirm deleted IDs are unknownItem. B unchanged. |
| `read-delete` | iPhone / existing peer | Existing replica applies the entity/edge deletions and surviving action update correctly. Pending upload work remains empty. |
| `reopen` | iPad / owner, new process | Original store and engine state reopen and retain the final graph. Exact server comparison passes without local edits or uploads. |
| `read-delete` | iPhone / fresh | A second, newly created pair of empty stores recovers only final surviving primitives, plus unchanged B. No source data copy and no upload feedback. |
| `audit` | iPad / owner | Complete local application-node inventory and complete server-zone modification inventory match exactly: four surviving application records in A and one in B, with no unexpected records. Read-only audit. |
| `read-audit` | iPhone / fresh | The recovered replica passes the same complete local/server inventory comparison, including every record body and graph boundary. Read-only audit. |

Assertions cover typed binary data, explicit null, UUID, integer/string values,
fixed dates, tags/groups, property removal and all primitive kinds. Local checks
use GraphRecord reads through the graph scope. Server checks independently fetch
each known record ID and decode CF01; final audits additionally enumerate complete local application
IDs and complete server-zone modifications from a nil token (100-record bound,
moreComing refused). Native SQLite contents are not used to infer transport success. Nonempty server tags are actual CloudKit metadata.
No fake tag or in-memory transport bus participates in these device stages.

The writer remained alive through server verification and, after updates and
deletions, independent peer observation before the next mutation. After the
initial server-confirmed seed, an attempted same-iPad peer launch returned
CoreDevice error 10004 without a PID. Listing the run directory showed only the
owner directory, so that peer stage had not started. No mutation was replayed.
The actual baseline peer stage subsequently ran once on the iPhone. Subsequent
restarts explicitly terminated the acknowledged prior PID before requesting a
new acknowledged launch. Launcher receipts and stage reports remain separate
facts; no missing report was treated as success.

Private raw evidence is retained outside the repository: signed build metadata,
pinned-runtime file, launch tickets/PIDs/receipts, ten stage reports and
protected account-comparison/session files. The original bridge source is retained
privately; a second signed host build adds only the two final read-only inventory
audits while keeping the same pinned production runtime. Reports expose stage outcome/checks,
not application payloads or account values. The disposable stores/zones remain
available for diagnosis; no cleanup or wipe is implied by this result.

## What remains open

This closes only the bounded T01 private insert/update/delete/reopen/independent
recovery check for this small fixture and device pair. It does not establish:

- genuine concurrent server conflicts/CAS recovery or a conflict resolution policy;
- CKAsset staging, attachment integrity/backup or file sharing;
- zone sharing, participant permissions, invitations, revocation or account changes;
- automatic/background scheduling, offline/rate-limit behavior or graph pause;
- interruption inside native/engine publication, power-loss or joint backup restore;
- schema deployment to Production, supported scale/resource budgets or public activation.

Initial CI process-exit cause remains unknown. The physical restart stages occur
after successful server/peer observation; they are not kill-during-commit tests.
No whole-container completeness or global synchronization certificate is claimed.
