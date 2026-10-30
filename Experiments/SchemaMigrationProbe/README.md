# SM01–SM03 — v1 native schema migration laboratory

Status: six local controls and both physical additive migration routes executed;
see the [retained result](../../docs/design/results/schema-migration-2026-10-30.md).
The first host transport/report naming failure is retained separately. Retain the final linked result rather than treating this protocol as
acceptance. This laboratory deliberately uses internal Graph/native framework
adapters, not only public v2 APIs.

## Purpose and boundaries

Compare the production v1 native shape, the adopted native identity shape and an
experimental node-version shape. The base factory's model construction matches
release 1.0.0; its difference is a fresh-model factory instead of the cached
constructor. Record the pinned source blob and model hashes in execution evidence.
The v1 model already has `appDataVersion` on property-detail rows. The optional
`ge2DataVersion` in this experiment is a separate **node** attribute, without a
default; it does not adopt mandatory application versioning or compatibility floors.

- `v1`: `Model.makeModel()`, with a laboratory model identifier only.
- `native`: v1 plus optional `ge2GraphID` / `ge2NodeID` String columns and native
  compound indexes, identical entity hashes to the current native candidate.
- `versioned`: native plus optional Integer64 `ge2DataVersion` on Entity,
  Relationship and Action. This is not a public schema selection.

The four-node synthetic fixture contains two entities, one directed relationship
and an action, fixed dates, tags/groups, binary values, labels and explicit
fixture UUIDs. These UUIDs permit exact comparison; they are not a generic v1
identity conversion algorithm. No v2 catalog/root/membership activation is
performed, and a successful schema migration is not successful v1-to-v2 adoption.

The library's production model/openers, normal migration defaults, data codecs
and native ownership contract remain unchanged. Native schema migration is an
internal GraphEvo responsibility; the public consumer migration manager targets
application data. RecoveryV2 remains an example, not the manager template.

## Local controls

```sh
swift test --filter SchemaMigrationLaboratoryTests
```

The tests cover v1→native→versioned lightweight transitions, staged custom pre/post
writes, a deliberately failed handler with a protected source copy, overlapping
laboratory owner refusal and rejection of incomplete four-row imports. Inspect scalar/binary values and topology, not only row
counts. Successful fixtures are removed only after explicit native detach; failed
fixtures remain available for diagnosis. Process-kill/power-loss coverage is a
separate assertion, not established by a thrown handler error.

Staged work uses the migration manager's container and generic Core Data fetches
inside this explicit framework adapter. Normal post-open writes and snapshots use
Graph Node facades. Native stage callbacks are synchronous, so they use the
context's queue API; this is not the proposed public async execution contract.
Freeze model checksums before constructing model references.

## Disposable signed host

```sh
python3 Experiments/SchemaMigrationProbe/prepare_demo.py \
  /path/to/configured/GraphEvoDemo /tmp/new-schema-migration-host
xcodebuild build -project /tmp/new-schema-migration-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/schema-migration-build -allowProvisioningUpdates
```

The configured source demo is copied, never edited. Its authorized Development
container and signing stay in the external copy. Use the acknowledged launcher
from PublicMirroredProbe. The app delegate retains the view model's native owner
independently of presentation; a launch receipt and scene acknowledgement are
separate from the stage's report and from cloud/replica evidence.

CLI: `--launch-ticket <fresh-ticket> --schema <stage> <run-UUID> lightweight|staged`.
Every stage reserves `<stage>.report.json` once; transport names never share
report paths. Legacy `<stage>.json` reports also prevent stage replay; neither writes nor native sharing are
replayed on a missing report. State and protected transports live under:

`Library/Application Support/GraphEvoLaboratory/SchemaMigration/<run>/`

The host seeds v1 files, then migrates the **same** files. Different-account
hardware uses one explicitly invited private share, accepted into the peer's
shared store. Only synthetic fixtures are shared. The owner remains alive until
independent peer observation; local save/share metadata/setup are not export
barriers. Never use production stores, silently reset cloud/schema, copy an
actively open SQLite family as a backup or claim a global sync pause.

| Ordered stage | Assertion / discipline |
|---|---|
| `identity`, each device | Protected account-scoped transport; no Graph store is created. Transfer peer identity only through private files. |
| `seed`, owner | New v1 fixture, baseline archive and one native share/invitation. Failure retains its original state; no second share fallback. |
| `peer-join` | Accept the pinned invitation, recover all four baseline records and compare exact values/topology. |
| Stop owner + whole-directory backup | After independent baseline observation, terminate only the acknowledged owner PID and copy the complete owned directory. No native owner remains while the source is copied. |
| `migrate`, owner | Reopen the same v1 file with versioned target and selected lightweight/staged route; capture model changes, handler order, values and native events separately. |
| `peer-handler`, staged peer | Observe whether handler-only updates arrive on the still-v1 peer before any ordinary post-open write. A bounded deadline is inconclusive observation, not proof that changes can never export. |
| `peer-version-one` / `peer-fresh-one` | Observe native version 1 and projections through the upgraded existing peer or a fresh pair **before** any ordinary post-open write. |
| `post-save`, owner | Explicit distinct ordinary context save with native identities and node version 2; it is not replay of a handler. |
| `peer-old` | Read through the old native model; new columns are not interpreted by that reader. |
| `peer-new` | Migrate the existing peer pair to the new shape and require exact projections, labels and version 2. |
| `peer-confirm*` | Distinct read-only final confirmations of version 2, bound to a fresh launch-ticket nonce. |
| `peer-fresh` | Open a separate fresh local pair for the already accepted account; independently recover the cloud state, not a copy of the owner's SQLite. |
| `identity-refresh` / `invite-prepared` | Explicit continuation after the retained host naming failure: refresh only the protected identity, verify original baseline, and assign only if no share mapping or durable assignment intent exists. Never replay seed. |
| `finish-invitation` | Explicit continuation restricted to an existing mapped share; no assignment fallback. |
| `diagnose` | Read existing v1 rows/native share mappings only. Missing/failed metadata does not authorize another native assignment. |

The collector requires each report's acknowledged `launch.json` and `receipt.json`
beside it and compares its process/ticket binding.

The snapshot's `stageOnly` property isolates handler-produced changes from the
ordinary save: the latter does not overwrite it. Retain explicit fields in the
results to avoid attributing later normal writes to the handler. Permission,
partial import, duplicate identity, event errors and decode failures remain
visible. Reports are private artifacts, not payload logs to commit.

## Acceptance

Retain initial failures and exact build/model/OS scope. Establish separately:
local structural migration, local transformed data, ordinary-save replication,
handler-write replication, existing-peer reopen and fresh independent recovery.
Do not infer heavyweight/staged support from an additive lightweight success.
Source/codec completeness, interrupted activation, graph/share conversion and
mandatory production v1 migration remain distinct work. No release/tag or default
schema selection follows from this experiment.
