# C02b local native identity prototype

This package-internal laboratory compares the current public full-inventory
adapter with a different model's optional native identity columns, with and
without a configured compound fetch index. Read the
[contract](../../docs/design/graphevo-2-native-identity-experiment.md).

```sh
swift build -c release --product IdentityLookupProbe
swift build -c release --show-bin-path
python3 Experiments/IdentityLookup/run.py --executable /absolute/bin/IdentityLookupProbe \
  --output /tmp/new-native-identity-run
```

Use `--cases smoke --repetitions 1` for functional screening. Defaults: five
fresh-process repetitions per non-seed/conversion operation on six cases, including an action with 500 subjects and 500 objects.
Every case creates a current-layout local store, closes it, copies its complete
directory twice, explicitly migrates each copy to a separate destination, and
validates/backfills identity columns before activation. All sample records,
including kinds/endpoints/dates/opaque/null data and one 10-MiB owned attachment,
are fingerprinted before/after conversion. The original source SQLite hash must
remain unchanged by conversion. No automatic production migration is enabled.

Entity/Relationship/Action reads and Entity patches use the same node/fields on baseline and both native variants.
Operation times include context scheduling and commits, exclude native open;
whole-process time and final RSS are recorded separately. Final RSS is not a
sampled peak. Full graph integrity is explicitly and separately measured.
Both use the normal runtime owner, leases, queues, query-generation pin and
commit guards through GraphStore operations. A package-only laboratory opener
selects the prototype adapter; default public openers never select it. Baseline
operations retain full-inventory routing/format validation; prototype calls use target/reference checks.
They are not equivalent production APIs. Never report the ratio as a ready-to-ship
GraphStore speedup. The configured index is not proof of a particular SQL plan.

Point lookup does not certify unrelated raw metadata or a missing column. An
activated local fixture has passed full validation/backfill; partial cloud import
and returning old writers are deliberately unsupported here. CloudKit/native
assignment, pair-store conversion and runtime leases need integrated acceptance.
Do not point this runner at real app/cloud stores, retry consumed stages or
commit generated stores/logs. The source/destination and copied auxiliaries stay
outside Git. Successful conversion of this alpha layout is not full v1 migration.

The [retained result](../../docs/design/results/c02b-native-identities-2026-10-27.md)
includes two rejected high-degree resolvers. The final candidate batches UUIDs and
selected endpoint metadata, prefetches topology without property bodies, and uses
the facade local view for changed owners. Whole-graph validation additionally
snapshots all payloads and is stronger than one baseline public record read.
Use the aggregate `GraphEvo-Package` Xcode scheme to run package tests.
