# C02a — batched reserved metadata experiment

Status: experimental branch `codex/v2-cost-experiments`, not integrated or a
schema decision. Baseline: C01 commit `e2177e04952eca2150450598008d7cbe88711a5c`.
The [consolidation plan](graphevo-2-consolidation.md) defines C02's wider goal;
this first experiment retains full inventory and all membership/integrity checks.

Variant A builds a Session-local index of reserved property rows, fetched in
bounded owner batches through a queue-confined facade helper. It does not fetch
application property rows, cache across operations, save, obtain permanent IDs
or change any public/model/layout contract. Metadata values are accessed lazily;
new facades fall back to the original lookup and duplicate-name cases retain
the facade's original selection. Existing checks still reject invalid/missing/
duplicate IDs, wrong membership, unresolved endpoints and invalid format lists.

Use normal managed-object fetches, with
[includesPendingChanges](https://developer.apple.com/documentation/coredata/nsfetchrequest/includespendingchanges)
explicitly enabled, rather than dictionary projections that exclude pending
changes. The first local matrix uses the unchanged C01 harness and budgets in
fresh processes, with copied standalone baseline/variant binaries retained
externally. Query byte-budget refusals are expected, not optimized away.

Variant A passes 467 macOS tests, including three new regression tests (one with
both SQLite/in-memory cases): pending edits across 128-owner boundaries, all
node kinds, corruption rejection, other-graph isolation and fresh reads after
repair. Its first eight-case matrix shows substantial read/patch/query gains,
but small-fixture seeding regresses and some observer memory peaks grow.
The next comparison tests batching only persisted owners; detailed retained
results and the selected experimental candidate will follow without claiming
that C02 or production/sharing acceptance is complete.

## Variant B — persisted owners and explicit resource routing

Variant B keeps Variant A's metadata reads for persisted owners, separated by
native node kind and persistent store, in batches of at most 128 owners. Each
request sets affectedStores explicitly. At most two persisted nodes, temporary
owners and newly introduced facades use the original lookup; unsaved metadata
rows on persisted owners remain visible through includesPendingChanges. Native
values stay lazy, and no index crosses a Session, context or handle boundary.

This addresses the first variant's insertion regression rather than dropping
validation. Full native candidate inventory, membership/endpoint checks, format
validation, duplicate-ID detection and A7 budgets are unchanged. It does not
complete C02's goal of eliminating full inventory or the C03/C04 work.

Additional tests use two independent SQLite resources, persisted-owner pending
patches, and a unique secure transformer that records/fails reads of another
graph's metadata. The selected graph must not decode that foreign value while
reading the foreign graph must visibly exercise the failure. The transformer
uses Apple's supported [secure transformer family](https://developer.apple.com/documentation/coredata/handling-different-data-types-in-core-data).
The test-only model/transformer does not alter the library model.

See the [comparison result](results/c02a-metadata-costs-2026-10-27.md) and
[physical read-only procedure](../../Experiments/C02MetadataProbe/README.md)
for measured outcomes, limitations and the retained preferred candidate.
