# GraphEvo 2 — consolidation after A1–A8

Status: started 2026-10-27 after A8 PR #77 merged into `codex/graphevo-2`
(`caa12129cd535c2ffd8bfbbf7e302a223d04815a`). Remain alpha: this is the
integration baseline for consolidation, not schema/API freeze or beta entry.
Read the [delivery plan](graphevo-2-delivery-plan.md),
[decision register](graphevo-2-decisions.md) and
[post-alpha checklist](graphevo-2-post-alpha-checklist.md).

## First finding and scope

A1–A8 established functional contracts and native framework feasibility. C01
now measures their combined implementation through a reproducible independent
consumer. This separates correctness from the cost of the candidate storage and
execution strategy. Review the [C01 measurements](results/c01-cost-baseline-2026-10-27.md)
before selecting a replacement representation.

The accepted file identity/exclusive ownership model remains the starting point
(M12). The current content representation and full-inventory execution strategy
are candidates to change. Mandatory v1 data migration, graph/share boundaries,
whole-content source protection and visible partial-import errors remain binding.
Do not publish a larger memory/size envelope just by raising query budgets.

## Measured work and proposed next increments

| Increment | Concrete work | Reviewable exit |
|---|---|---|
| C01 — integrated cost baseline | New temporary local fixtures, isolated Release processes, scalar CRUD/query/list/read and one/eight observer cycles | Retained correctness assertions, diagnostic counters, time/memory/storage scope and prioritized bottlenecks; physical/production limits remain unproven |
| C02 — selective identity/catalog/session access | Prototype targeted metadata/identity access and reuse within an operation; compare retaining the candidate native model with adding queryable native identity/membership fields if required | Fetching/patching one node stops requiring full application-record inventory; graph ownership, duplicate/invalid identity detection, remote changes and snapshot semantics retain an explicit validation route; compare against C01 |
| C03 — attachment metadata/content separation | Prototype metadata-only reads and separate binary storage without JSON/base64 content wrapping; keep file ID/owner/public lifecycle as the starting point | Unrelated scalar queries/counts/projections do not materialize attachment bytes or exhaust a byte budget because files exist; metadata listing avoids full content hashing; actual content reads still validate identity/size/digest |
| C04 — shared observation work | Reuse selective inputs/refresh work where contracts permit; compare shared snapshots and dependency-based invalidation against the conservative A8 baseline | Several observers avoid independent repeated full scans while preserving related/action/file invalidation, cancellation, failure states, per-handle shutdown and each query's explicit budget/view contract |

C02/C03 are closely related and may challenge the schema together. These are
proposed implementation directions, not a frozen native model or an inference
that a transformable value can be indexed as an ordinary scalar. Benchmark
alternative representations before selecting their query capabilities. C04
must retain the correctness of broad invalidation until narrower dependencies
are demonstrated; fewer notifications alone is not a valid optimization.

C01 has no product latency/RAM acceptance threshold. Select such thresholds
from realistic library/application scenarios and physical devices, not from
these synthetic desktop medians. Do not replace the independent consumer with
an app-specific API to meet a benchmark.

## First experiment checkpoint

[C02a](graphevo-2-metadata-experiment.md) compares the baseline with batching all
reserved metadata (A) and persisted-owner batching (B), without schema/API
changes or cross-operation caches. The [result](results/c02a-metadata-costs-2026-10-27.md)
retains 596 timing samples, 469 regression tests, 19 targeted sanitizer tests and
read-only iPad/XR checks. B is preferred on the experiment branch: identity reads
and queries improve substantially and A's insertion regression is avoided.
Observer memory increases in some cases, full inventory remains, and new native
sharing writes have not been revalidated. C02/C03/C04 gates remain open.

## Required checks for candidate changes

- Rerun the same C01 fixture matrix and assertions on the integrated candidate.
  Explain input/measurement changes and retain failed results; do not silently
  loosen budgets, reduce fixture sizes or remove mandatory validation to win.
- Verify all node kinds, endpoint/owner deletion, tags/groups, unknown values,
  null/absent data and identity/reference preservation. C01's Entity-only scalar
  fixtures do not establish the full model contract.
- Include local alpha conversion and mandatory v1 mapping/codec feasibility.
  Public attachment metadata and original bytes must remain recoverable; ordinary
  v1 binary values are not implicitly reclassified as owned files.
- Revalidate actual same-account and cross-account mirroring with the selected
  schema. Attachment metadata/content and every new native row must remain in
  the graph's existing share boundary, including participant assignment and
  partial-intent recovery. Native public APIs remain the synchronization owner.
- Preserve complete backups, journal/source protection, access/account handling,
  cancellation and local-view semantics. No persistent cache may treat native
  identity mappings or notifications as import completion or distributed locking.

## Before beta

After the cost/representation review, reconcile schema/API and supported query,
file and observer envelopes. Resolve the stable processing contract (O04),
platform/process scope, account/conflict/recovery limitations and alpha-store
policy. Demonstrate representative end-to-end v1 local/cloud migration
feasibility, including the coordinated cutover and returning old devices.
Only then review beta entry. Complete migration tooling, real app adoption and
release acceptance during beta; mandatory data migration cannot become optional.
