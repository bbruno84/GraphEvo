# GI01 — one graph controller, dedicated stores, native cloud import scope

Experiment-only branch from `codex/graphevo-2`. Do not merge this laboratory or
change the integration architecture merely because the probe runs. Retain the
result, then choose and separately develop a production solution. MC01's closed
copy feasibility does not establish independent per-graph physical publication.

## Question

Can a controller with a dedicated S02 private store (or private/shared pair)
keep only its own logical graph while native Core Data mirroring uses the same
CloudKit container and model as another controller? Does recovery into strictly
new resources preserve that physical partition?

The probe writes A only through original controller A and B only through original
controller B. Each uses a distinct GraphDatabase/native owner and resource URL.
Both graphs get distinct owner-only share zones. The test inspects the unfiltered
resource catalog and validates exact synthetic roots/children/edges/actions;
filtering an app-facing graph handle is not evidence of physical isolation.

## Safety and protocol

Use only the authorized Development test container, owner iPad and different-account
XR. No cloud reset, zone purge or old-fixture edits. Public GraphEvo APIs only;
S02/default model and implementation remain unchanged. Existing account data may
arrive; classify only new run-bound A/B, retaining unrelated counts without IDs.

```sh
python3 Experiments/GraphStoreIsolationProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/new-GI01-host
```

Build/sign Debug against the integration code. Verify actual signed Development
container, source/executable hashes, install on the two devices and launch with
the acknowledged PublicMirroredProbe launcher:
`--graph-isolation <stage> <new-run-UUID>`. Every stage is one-use; bind each report
to the actual PID/launch ticket/scene. Never replay a consumed mutation.

1. iPad `prepare` creates only the case/transport directory. XR `identity` opens
   its identity resource pair and writes the protected recipient transport.
   Transfer only identity.json to the owner case directory.
2. iPad `seed-recover` opens two independent private controllers, seeds exactly
   one new graph per controller, prepares distinct zones and invites the pinned
   recipient to both. It then opens two strictly absent private directories,
   conceptually intended for A and B, with identical supported mirroring options.
   Observe full A/B payloads in each fresh/original resource. Keep all owners alive.
3. Transfer only fixture.json and invitation-A/B.json to XR. XR `accept-separate`
   opens two independent private/shared pairs, accepts A via pair A and B via pair B,
   then observes the actual graph catalog/payloads of both resource groups.
4. XR `recover-shared` repeats only recovery into two new absent pairs using the
   already accepted original invitations. No native stores/sidecars are transferred.
5. After independent observations, stop only acknowledged probe PIDs and collect
   whole case directories into protected external evidence. Public read-only
   inspection of each copied physical resource distinguishes real imported data
   from accidental wrapper/runtime catalog sharing.

A complete foreign graph in a dedicated resource is a decisive counterexample.
Missing data, setup/export events and an elapsed observation window do not prove
isolation. Report execution failure/incomplete recovery separately from a
counterexample. No command exposes account IDs or invitation URLs in logs.

## Interpretation

Separate files, distinct zones, controller-facing Graph handles and physical
import partitioning are different properties. This probes the supported current
NSPersistentCloudKitContainer configuration, not all conceivable architectures.
Do not infer that 1 controller : 1 Graph is impossible from a failed physical
partition; do not infer that native per-graph import filtering exists either.
A result must distinguish the controller abstraction from exclusive physical
ownership, and leave the production decision to the next design discussion.

## Physical-file confirmation

After stopping the acknowledged owners and collecting complete case directories,
prepare an inspector outside the repository:

```sh
python3 Experiments/GraphStoreIsolationProbe/prepare_inspector.py /tmp/new-GI01-inspector
swift run --package-path /tmp/new-GI01-inspector Inspector /private/evidence/fixture.json /private/evidence/fresh-private-A/private.sqlite
```

Pass only owned closed evidence copies, never application/production stores. The
inspector opens one file at a time read-only with no CloudKit container and checks
both fixture graphs' exact values, endpoints and integrity. Inspect each original/
fresh owner private store, participant/fresh shared store, and XR private controls.
Use public Core Data metadata APIs to check S02 and distinct native store UUIDs;
do not parse private SQLite or CloudKit tables.

The [GI01 result](../../docs/design/results/gi01-graph-store-isolation-2026-10-30.md)
records the counterexamples and scope. The integration branch stays unchanged.

## Single-owner control: B's store never opened

The initial stages retain both original native owners, so they do not isolate
whether B must be open elsewhere. Follow up with the one-use `recover-A-only`
stage on the already exported fixture, using a new `single-private-A` directory:

1. Record and stop confirmed laboratory processes on both devices. Verify none
   remains before launching the controlled owner process.
2. Open exactly one private GraphDatabase/native owner on iPad. Open/validate
   only graph A; never open graph B or any original/fresh B store in this process.
3. Retain the sole owner for a bounded 90-second native import window after A
   becomes complete. Perform no application writes, invitations or reassignment.
4. Await native owner close before writing the completed stage report. The report
   leaves B content inspection deferred; its default counterexample flag is not
   an isolation result for this stage.
5. Collect only this closed directory into new protected evidence. Inspect A/B
   through the offline public read-only inspector, without a CloudKit container.
   This avoids loading a B graph handle while cloud mirroring is active.

A complete B in that file is a positive counterexample with B's store closed;
absence after this finite window would remain inconclusive. Preserve the process
inventories, sole-owner count, source/executable hashes and offline result.

## Independent Core Data proof and never-cloud local control

The Graph-based offline inspector still uses Graph's adapter. To independently
verify physical rows, prepare three separate executables outside the repository:

```sh
python3 Experiments/GraphStoreIsolationProbe/prepare_native_reader.py /tmp/new-GI01-native-reader
swift build --package-path /tmp/new-GI01-native-reader
swift run --skip-build --package-path /tmp/new-GI01-native-reader ModelExporter /private/evidence/S02-model.archive
swift run --skip-build --package-path /tmp/new-GI01-native-reader LocalControl /private/evidence/new-local-control
swift run --skip-build --package-path /tmp/new-GI01-native-reader CoreDataReader /private/evidence/S02-model.archive /private/evidence/fixture.json /private/evidence/single-A-closed-case/private.sqlite
```

Run CoreDataReader again in a new process for each local-control file using the
local-control fixture transport. Pass only owned closed evidence, never production.

ModelExporter uses Graph only to obtain the base structural model, adds the exact
S02 identity columns/indexes, switches managed classes to generic NSManagedObject
and verifies unchanged entity hashes. It never opens a store. CoreDataReader has
**no GraphEvo dependency or import**. It reads the exported model, verifies store
compatibility, opens exactly one file with a plain NSPersistentStoreCoordinator
and read-only/no-migration options, and binds every request with affectedStores.
Dictionary requests select only native ge2GraphID/ge2NodeID/type attributes; a
second object-ID request confirms every result belongs to that exact opened
store. No managed subclasses, Graph adapter, application decoder, cloud container
or private SQL/tables are used.

LocalControl creates two new stores with public local-only opening, writes A only
in its store and B only in its store, verifies separate catalogs and closes every
lease. No CloudKit identifier is configured. Inspect both files through the
independent CoreDataReader and compare with the previously cloud-synced single A
file. Record native row counts/identity checks, not a semantic payload claim for
this dictionary-only reader.
