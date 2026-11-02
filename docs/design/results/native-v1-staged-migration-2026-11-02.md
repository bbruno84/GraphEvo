# MF11 — native staged v1 migration validation

Date: 2026-11-02. Scope: package-only stopped local v1 conversion to the
existing S04 schema. Local review is complete on
`814a64d24a9bbb6448c74da46922de4dd6a17e03`. Required full remote checkpoint and
integration through [PR #141](https://github.com/bbruno84/GraphEvo/pull/141) remain
pending; final status notes change documentation only.

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
- Full local iOS 18.5 Simulator run: 957 functions passed, zero failures and one
  known skip. Focused native/bootstrap/conversion/activation checks pass 60
  functions; focused adoption/native/activation checks pass 38 functions.
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

## Remote checkpoint attempts

[Full checkpoint #374](https://github.com/bbruno84/GraphEvo/actions/runs/41506964943)
did not pass. macOS never acquired a hosted runner. The iOS run reports one
failure: `GraphAdoptionTests.explicitAdoptionBacksUpAndPreservesV1DataReferencesAndIDMapping`
exceeded its existing one-minute execution allowance. That unchanged test passes
in the focused adoption/native/activation run and the complete local iOS run.
No source or test allowances were changed to suppress the failure.

[Full checkpoint #375](https://github.com/bbruno84/GraphEvo/actions/runs/41510703190)
retries the same source head. Both jobs were cancelled without executing after
15-minute waits. GitHub reports that hosted macOS arm64 capacity prevented runner
acquisition. Neither cancelled nor skipped jobs establish a tested checkpoint.
The PR remains unmerged until a complete reviewed full checkpoint succeeds.

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
