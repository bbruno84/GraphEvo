# A7 retained-fixture query reader

Read the source demo README/AGENTS. Prepare a disposable configured copy, keeping
the original checkout/signing settings unchanged:

```sh
python3 Experiments/A7NativeProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoA7Demo
xcodebuild build -project /tmp/GraphEvoA7Demo/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoA7Build -allowProvisioningUpdates
```

Use the original A5 owner iPad and original protected run UUID. Launch with
`--a7 <A5-run-UUID>`. This reserves a new `a7-queries.txt` ticket beside the
retained A5 private/shared files; never replay a reserved ticket or reseed a
failed reader. It reads the pinned fixture envelope before native opening.
There are no application edits, invitations, acceptance or share-creation calls.
Native opening may perform ordinary framework bookkeeping/imports; this is not
an immutable-file inspection guarantee.

The owner fixture must still contain A8/B5 after the successful A5 lifecycle:
three A Entity, three Relationship, two Action objects; B retains its two Entity
objects. The reader checks AND filters, scoped count, relationship/action endpoint
predicates, related-node matching, label projection, integer sum, current-state
keyset pages, cycle-safe traversal, foreign-graph rejection and native candidate
allowance refusal. It reports counts/charged work only, never payloads, identity
or invitation material. No cloud reset or mutation fallback belongs to this probe.
This validates one-shot local reads on a physical device, not fresh replica
recovery, live observation, durable processing or a performance benchmark.
