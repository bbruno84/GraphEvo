# MF11 — native staged v1 migration validation

Date: 2026-11-02. Scope: package-only stopped local v1 conversion to the
existing S04 schema. Initial local review covered
`814a64d24a9bbb6448c74da46922de4dd6a17e03`; the follow-up below corrects its seed
publication window. Required full remote checkpoint and
integration through [PR #141](https://github.com/bbruno84/GraphEvo/pull/141) remain
pending. Earlier status notes changed documentation only; the follow-up changes
runtime seeding, its regression test and the matching contract.

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

- Full macOS package run: 960 functions passed (331 legacy, 520 store, 79 runtime,
  30 model).
- Full local iOS 18.5 Simulator run: 958 functions passed, zero failures and one
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

## Follow-up review — seed publication

The original runtime copied the unmarked v1 input directly to the requested
destination before writing workspace/document metadata. A failure during that
metadata step could leave an ordinary v1 file at the destination: public legacy
opening could accept it, while native bootstrap recovery could not recognize it
as this operation's workspace.

Seeding now clones into a fresh temporary native location, stamps all admission
metadata there, then publishes with Core Data whole-store replacement. An
injected stamping failure proves the requested destination remains absent, the
source remains unchanged, temporary files are cleaned up and a normal retry
publishes matching workspace/document metadata. Ordinary runtime and legacy
admission refuse that published workspace. No new persistent format or automatic
reclamation of existing foreign files is introduced.

The current local full counts above include this new runtime regression. Both
complete platform suites, independent consumers and a fresh private-source
conversion are repeated after the fix. Existing test allowances are unchanged.
Physical interruption during native file replacement, platform capacity and
abrupt-termination cleanup retain their separate gates.

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

[Full checkpoint #378](https://github.com/bbruno84/GraphEvo/actions/runs/41514422610)
contains the seed-publication correction. The iOS job again exceeds an existing
one-minute allowance, this time in
`GraphCoordinatorTests.initializationAndPartialLoadCleanupFailuresRetainRegistration`.
This is a different case from #374. The raw native diagnostic bundle was not
requested for these attempts, so the timeout summaries do not prove a blocked
native stack or a specific production defect.

A test-fixture follow-up serializes independent cases in the native migration and
cloud activation suites, reducing simultaneous backed-up migrations from those
groups. This tests the resource-contention hypothesis; it is not a declaration
that the prior failures were harmless. Explicit four-operation task-group
migration and lifecycle race tests keep their existing concurrency. All cases,
assertions, payloads, deadlines and full-profile selection remain intact.
Production runtime/store code is unchanged from the seed-publication correction.
The revised execution still requires a complete successful remote checkpoint.
Local counts remain 960 macOS and 958 passed iOS functions with the known skip;
the coordinator cleanup case completes in 12.31 seconds and the explicit
four-operation migration case in 0.71 seconds. The complete local store suite
now takes 33.22 seconds, versus 26.67 seconds in the prior local run. Conditions
are not controlled, so this is not a speedup claim: the change limits overlapping
fixture work, and remote validation must assess the hosted-runner outcome.

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
