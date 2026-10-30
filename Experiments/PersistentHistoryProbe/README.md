# PH01 — Persistent History as Graph change discovery

Experiment only, based on `codex/graphevo-2` after #106 (`c3e7583`). Keep the
prototype on `codex/v2-persistent-history-experiment`; no PR or merge. This probes
framework behavior to choose an implementation path, not an outbox implementation.
The previously proposed atomic mutation-intent journal has not been implemented.

## Question and models

Can public Core Data Persistent History identify Graph application records after
property/tag/group/topology changes, deletes and cascades, survive reopen with a
persisted token, and distinguish imports without suppressing query observation?

The negative control uses the actual public S02 native opener. The positive model
is a fresh S02 factory with `preservesValueInHistoryOnDeletion = true` only on
ge2GraphID/ge2NodeID of ManagedEntity, ManagedRelationship and ManagedAction.
It has a lab-only physical identifier `GraphEvo.PH01.preserved.1`. No columns or
entities are added. Attribute preservation changes entity hashes; normal S02
openers refuse these files. This does not select S03 or change a default opener.

Fixtures use normal GraphDatabase/GraphStore CRUD, queries and attachments.
The package-only helper reads public NSPersistentHistoryTransaction/change/token
APIs. It opens no cloud container and parses no private SQL tables. The controlled
import seam patches through the same native facade adapter on its context queue,
with a distinct persisted transaction author. No application snapshots, manual
mutation tracking or queue properties are written to discover changes.

## Running and interpretation

```sh
swift test --filter GraphPersistentHistoryLaboratoryTests
```

The suite has eleven test functions and nineteen expanded cases, including two
parameterized functions. Run it on macOS and with the GraphEvo-Package scheme on
an iOS Simulator; keep result bundles and raw logs outside Git. Fixtures are fresh
external temporary directories and are closed before removal. No account, device
store, existing native mirror zone or cloud reset is involved.

History reading holds the existing native-operation writer gate for a fixed
local cut. The helper returns detached transaction/row identity observations,
then conservatively reduces candidate save/delete IDs. It resolves live detail
owners and correlates node events with preserved delete identities. Deleted
property/tag/group rows can have no live owner: the fixture tests whether native
node relationship changes and later node deletes still cover the affected ID.
Imported authors remain in the read history but are excluded from candidates;
unknown authors are an explicit failure in this bounded reducer.

The complete retained range is read in this experiment. The reducer is not a
proof of arbitrary paginated correlation, imported/local conflict safety or a
production streaming algorithm. Extra inverse-node updates can yield conservative
candidates whose application snapshot has not changed. No exact minimal-delta
claim is made.

The reopen test deliberately retains an old serialized token, collects changes,
closes/reopens the store and verifies deterministic replay before advancing the
token. It is not a process-kill, power-loss or atomic pending/checkpoint test.
A production processor must make its pending work durable before advancing the
checkpoint and scope tokens to graph/store identity. No history is purged here.

See the [result and implementation recommendation](../../docs/design/results/ph01-persistent-history-2026-10-30.md).
