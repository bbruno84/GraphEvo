# MF11 — native staged v1 migration validation

Date: 2026-11-02. Scope: package-only stopped local v1 conversion to the
existing S04 schema. Review and remote checkpoint pending.

## Selected route

A custom staged migration lets Core Data infer the additive physical schema hop,
with library handlers for typed values and stable logical identity projections.
Lightweight inference alone cannot transform the dynamic property representation
or establish the catalog, receipt and new synchronization lineage. The original
source remains read-only; a verified backup seeds an isolated target copy.

Identity preparation uses an ordinary source-model container under the same
pending runtime owner, detached before the target container loads. This preserves
inserted identity details during concurrent native migrations. The target handler
and post-load continuation share idempotent 128-row transformations. A durable
workspace marker prevents ordinary admission until validated catalog, fresh target
history baseline, pending saves and conversion receipt are complete.

## Local checks

- Full macOS package run: 959 functions passed (331 legacy, 520 store, 78 runtime,
  30 model).
- iOS 18.5 Simulator: 60 functions passed in native migration, retained v1
  bootstrap/conversion and cloud activation suites.
- All three independent consumers passed: legacy package consumer, Swift 6 model
  consumer and separate-process consumer.
- Manifest inspection and `git diff --check` passed.

Eight new migration functions cover complete graph/value preservation, payloads
above the retained atomic allowance, multiple row batches, partial conversion,
interrupted catalog sealing, empty history, concurrent identity maps, cancellation
after native admission and failed source-container detachment. The last case
retains native ownership in quarantine rather than reopening an attached file.
The parameterized interruption function exercises two failure boundaries.

The large-payload fixture uses 257 application nodes and 36 MiB binary properties;
no payload-limit override is passed to the default bootstrap. A separate local
private-source acceptance also passed fresh conversion, exact semantic comparison,
independent raw-archive/hash comparison, verified backup restoration and a new
process recovering the same receipt. Private stores, maps, reports and logs stay
outside the repository and are excluded from CI.

## Limits and remaining gates

No total property-byte allowance applies to the native route. Format-1 map,
receipt, row-count and history-preview limits remain; individual values/records
and Core Data migration still require working memory. This is not an arbitrary
size, bounded-memory or duration guarantee. Native store UUID preservation is
expected and differs from allocating new logical graph/node identities.

The explicit-limits overload retains the old bounded atomic recipe. Existing
uncommitted bounded workspaces are not reinterpreted as native migrations.
Public legacy opening, other source schemas, cross-process writer fencing,
production/historical acceptance, cloud cutover and beta acceptance are not
certified by these local checks. No CloudKit operation is part of this migration.
