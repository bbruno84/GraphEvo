# S01 runtime adoption — local validation (2026-10-30)

The explicit `GraphDatabaseSchema.nativeIdentity` factory now implements
[S01](../graphevo-2-persistent-schema.md), using `GraphEvo.v2.schema.1` as both
runtime schema identity and required persisted model identifier. Local, in-memory,
private-only mirrored, paired mirrored and local read-only native openings share
this factory. Default/current model selection is unchanged.

## Behavior and controls

- Preserve the twelve entities and existing fields/relationships. Add only the
  selected optional graph/node String projections and optional Integer64 node
  data version, without defaults, with the existing compound identity indexes.
- Validate uniform node layouts before native adapter admission. Reject partial
  identity/version combinations, wrong types/defaults/optionality/transience and
  missing S01 identity indexes. Historical identity-only laboratories opt out of
  the version column explicitly; their source fixtures are not silently updated.
- Confirm S01 entity hashes equal the versioned SM01–SM03 fixture, while differing
  from the historical two-column model. All nine detail-entity hashes remain
  equal to the base model. Factories return independent native model instances.
- Existing public local SQLite controls pass catalog/independent graphs, all node
  kinds, files, leases, queries, integrity and reopening. Unversioned writes leave
  the native version absent, including control and attachment rows.
- Offline private-only/paired containers exercise the selected model and both
  native load orders. Independent local read-only paths retain routing, mutation
  refusal and ownership rules. These are not native CloudKit assignment tests.
- Populated alpha.2 fixtures and same-S01-shape fixtures with an old identifier
  are refused before loading by local, read-only, private-only mirrored and both
  paired resource positions. No companion SQLite is created. Source filenames,
  durable SQLite/WAL and other artifact bytes are preserved; reopening with the
  original fixture schema still returns the original data.

## Retained diagnostic failures

The first added default-value assertion inside a Swift Testing macro caused the
compiler to select the nonthrowing Core Data callback overload. Move the throwing
count into an explicit local value; no production behavior was changed for this
test compilation correction.

The initial whole-directory byte oracle failed only for `OldAlpha.sqlite-shm`.
A separate control using just the public Core Data metadata inspection reproduced
that difference for both fixture variants. SQLite describes SHM as a coordination
cache without database content; its bytes are not a durable-data preservation
oracle ([SQLite documentation](https://www.sqlite.org/walformat.html#the_wal_index_or_shm_file)).
The corrected test keeps exact filename and every-other-artifact comparisons,
including SQLite/WAL, as well as original-schema semantic recovery. It excludes
only that source's volatile SHM bytes. No SQL/SHM internals are parsed or modified,
and no model gate, budget or semantic assertion is relaxed.

## Validation and limits

Full macOS package suite: **530 pass** (331 legacy-target including three new
shape controls, 112 store including the two-case source-refusal test, 64 runtime,
23 model). The Swift 6 ModelConsumer and independent-process ProcessConsumer
also pass, including explicit native selection. These desktop process checks do
not certify iOS App Group suspension or CloudKit synchronization.
Manifest, changed-document local links and diff formatting pass. Raw local logs are external under
`/tmp/graphevo-s01-*`; generated stores and logs are not committed.

No physical device/cloud stage or Production schema deployment is performed by
this increment. The separately retained SM01–SM03 result tested the same entity
shape under laboratory identifiers; it does not certify this runtime's complete
native assignment/recovery lifecycle. Keep that selected-model gate open.
Optional consumer-format APIs, admission/reconciliation of partial or later
old-format imports and mandatory logical v1 conversion are not implemented by
adding the column. No application version is inferred from the old property-row
`appDataVersion`, and no incompatible file is automatically converted or erased.
