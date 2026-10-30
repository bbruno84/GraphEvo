# MC01 — physical working-store copy and native-history publication

Question: can a consumer modify a closed copy locally and return the complete
store, then let NSPersistentCloudKitContainer export those already committed
transactions after publication, without a Graph diff or post-open application save?

This is an isolated experiment, not a public migration manager. PR #104 was
closed without merge at the maintainer's direction. Preserve the branch and
evidence as references; do not integrate this experiment implementation. Develop
a selected production solution separately from `codex/graphevo-2`. No copy-based
manager architecture or per-graph publication contract is selected by this result.

## Local matrix

`swift test --filter GraphStoreCopyLaboratoryTests` creates only disposable temp
S02 stores. It compares:

- Core Data `replacePersistentStore` copy into an absent destination.
- Whole-directory copy with every owner closed (not a live SQLite-file copy).
- Publication back to the original URL through `replacePersistentStore`.

Check store UUID, prior history/token usability, new insert/update/delete history,
property removal, endpoint edits, action preservation, create/delete within one
transaction, 2/3-MiB attachment contents and cascade removal, control graph and
reopening. Inspect only public metadata/history APIs, never private SQLite tables.
Retain bytes regardless of whether Core Data chooses external placement.

The stale-original counterexample deliberately changes the original after copying:
replacement overwrites the complete store, including unrelated graph edits. This
is a limitation demonstration, never a production-safe publication procedure.
The helper does not implement owner admission, stale-source checking or process
recovery. All callers are responsible for closed disposable resources.

## Device protocol

Use only the existing authorized Development container, owner iPad and
other-account iPhone XR. No schema reset, zone purge or old-fixture mutation.
Native shape is S02 (`GraphEvo.v2.schema.2`); default public paths are unchanged.
A new local store is not proof of an empty cloud account. Select only run-bound
fixture graph IDs; unrelated cloud graphs may exist.

```sh
python3 Experiments/StoreCopyProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/new-MC01-host
```

Build/sign Debug against this checkout. Verify actual signed Development
entitlements, preserve source/executable hashes, install on both devices, and use
the acknowledged launcher with `--store-copy <stage> <new-run-UUID>`.
The host reserves each report before work; reports bind run, launch ticket and PID.
Never replay consumed mutations. Retry only read-only report collection.

1. iPad `prepare`; XR `identity`. Transfer only protected run-bound identity.json
   to the already prepared owner directory.
2. iPad `seed` creates A and personal B, nodes/edge/action, two 2-MiB attachments,
   distinct owner share boundaries and one recipient invitation in that process.
   Transfer fixture.json/invitation.json to XR. Retain the seed owner.
3. XR `peer-before` accepts and independently verifies the exact baseline,
   attachment bytes, graph A mappings and B absence before replacing the owner.
4. iPad `copy-publish` verifies baseline, closes all graph/database leases, retains
   a whole-directory closed backup, copies to work via Core Data, and opens work
   locally without CloudKit. Apply ordinary Graph edits, remove a property, add a
   node, retarget an edge, delete an owner/file and replace an attachment with
   3-MiB content. Close work, verify history, and publish via Core Data at the
   original URL. Reopen mirrored without application writes. Verify local result,
   complete native mappings, unchanged share boundary and B control. Retain owner.
5. XR `peer-after` independently verifies exact values, topology, added/deleted
   nodes/files and 3-MiB content, with full native mappings and B absence.
6. XR `peer-fresh` uses a strictly absent fresh private/shared directory and the
   original invitation. Never copy a native store into this replica. Verify the
   same complete migrated fixture and mappings from the cloud.
7. iPad `owner-final` verifies result/B again after peer recovery. Only after this
   evidence may the acknowledged probe processes be stopped and evidence copied.

Protected reports/transports/stores remain outside the repository. Publish only
sanitized conclusions, checks, tested matrix and scope. No account identifiers,
invitation URLs, private record names or raw logs belong in Git.

## Acceptance boundary

A successful result supports a closed, exclusively controlled **whole-store**
copy/return route under the tested configuration. It does not establish per-graph
independent replacement, concurrent original writers, participant-side writable
copies, cross-file atomic pair replacement, power-loss recovery, cloud quiescence,
full v1 conversion, broad S02 account/conflict/scale acceptance or production rollout.
Native history is not a semantic quality check or a distributed lock. Keep manager
admission, backup, interruption recovery and ongoing imports as explicit follow-ups.
