# C02b native identity lookup — local evidence, 2026-10-27

Status at this checkpoint: initial campaign retained; batched campaign pending.

## Boundary and decision

This is a package-only alternative-model experiment after `c4b6745`. The default
model/public openers, integration branch and alpha tag are unchanged. No CloudKit
schema or device store is modified. Read the [contract](../graphevo-2-native-identity-experiment.md)
and [runner](../../../Experiments/IdentityLookup/README.md).

## Method

Release arm64 executable, macOS 27.0.1, fresh process per operation; five samples
per operation/case/variant. Process startup and store opening are excluded from
operation latency and recorded separately. OS caches are uncontrolled; these are
not cold-storage measurements. `residentAtEnd` is final RSS, not a sampled peak;
no peak-memory improvement is claimed. No local builds/tests run during timing.

The three variants use matched independent local fixtures: the public full
inventory adapter; optional native graph/node String columns without a configured
index; the same columns with a compound fetch index. All use normal runtime
leases, queues, read pins, writer serialization and commit guards. The prototype
checks the requested node/references; the public adapter also validates unrelated
application records. Their timings do **not** describe equivalent production
contracts or a drop-in API speedup.

Six cases: 100, 500 and 2000 entities; four graphs with 125 entities each; 100
entities plus one 10-MiB attachment; and 500 entities with an action referencing
all 500 as both subjects and objects. Every graph also has an edge and an action.
Each entity has five properties (including explicit null and an unknown encoded
value), tag/group and a stable date. File bytes repeat a deterministic 256-byte
pattern; this identity probe is not representative media storage evidence.

Each campaign creates an owned current-alpha source, closes it, copies its whole
directory twice, converts each copy to a new store with inferred mapping, then
validates/backfills/activates. Sample fingerprints preserve kinds, IDs, endpoints,
properties, dates, tags/groups and exact owned attachment content. Original source
SQLite hashes must stay unchanged. This does not prove full v1/local/cloud
migration. Conversion timings include backfill and validation, with one sample
per variant/case, and are not statistically stable estimates.

## Retained failures and first checkpoint

The first store-specific migration attempt failed on a disposable source with
Cocoa 134110 / SQLite 8 (`attempt to write a readonly database`). The explicit
copy-to-new-store probe uses the generic mapping manager instead. The failure
remains in `/tmp/graphevo-c02b-tests.log`; no production auto-migration is enabled.

Checkpoint `548807344d66335ff19ca893c3b240d52381ed6e` completed 528 rows. Its
native resolver issued three requests per endpoint: fast Entity results hid a
serious wide-action regression. These outcomes remain part of the evidence.

| Operation | Public full inventory, ms | Native columns, ms | Configured index, ms |
|---|---:|---:|---:|
| flat-500 read | 47.39 | 2.95 | 2.99 |
| flat-500 patch | 48.42 | 3.92 | 3.77 |
| flat-2000 read | 184.05 | 2.92 | 2.70 |
| flat-2000 patch | 192.16 | 4.18 | 3.87 |
| fanout read-action | 54.00 | 675.21 | 648.17 |

The revised checkpoint batches up to 128 distinct endpoint UUIDs, checking all
three node kinds per batch. It retains raw/native identity, membership, backing
object and duplicate checks. A 130-endpoint regression crosses the boundary and
rejects pending cross-kind duplicates and missing endpoint columns.
