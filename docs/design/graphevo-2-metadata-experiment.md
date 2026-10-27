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
