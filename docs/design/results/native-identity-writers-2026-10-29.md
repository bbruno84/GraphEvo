# Common native identity writers — local acceptance (2026-10-29)

Status: writer consolidation after reviewed #84/#85/#86 merged into
`codex/v2-cost-experiment-matrix` at `e2f6323`, `33225aa`, `0b933dd`.
Their prospective/actual merge trees match reviewed content; exact-head
macOS/iOS CI runs `40828821638`, `40830758724`, `40833451528` passed.
No v2 integration/tag promotion or default schema selection occurred.

## Change and coverage

An optional-model helper stamps native graph/node projections through common
new-row/control creation. The original prototype-only post-insert rescan/stamp
is removed. Default models have neither column and keep their existing behavior;
partial/mixed column definitions fail. Persisted projections are validated rather
than populated, preserving explicit conversion/backfill as a separate operation.

Common mutation admission checks controls/current projections and staged state.
Shared staging checks the model before journal reservation and common stamping;
finalization validates controls, staged and already-committed rows before links
or intent cleanup. It does not replay assignment or silently repair imports.

The package-only full-writer option uses ordinary mutation adapters while keeping
the same protected native point-read path in both modes. Acceptance exercises:

- Entity, Relationship and Action insertion and pending reads; separate graphs.
- File import/replacement with exact IDs, owner and bytes; replacement preserves
  logical identity and native projections.
- Owner/implicit-edge/file cascade, surviving action endpoints and reopen.
- Transaction rollback; persisted damaged projection rejects stamp/patch/delete
  without editing application payloads or filling the missing projection.
- Injected partial import makes guarded point lookup and common patch fail;
  after explicit fixture cleanup, valid absence and unchanged data recover.
- Partial native models fail before control allocation or raw identity stamping.
- Existing conversion/negative-audit, metadata, all-kind/wide-action, lifecycle,
  journal/plan and query/materialization regressions remain.

The old staged-import fixture now writes raw metadata explicitly rather than
using the common library stamp, preserving its intended missing-column case.
Initial new multi-assert contextRead tests needed explicit throwing closures;
that test typing was corrected without a production workaround.

## Verification

- Full local suite: 507 pass (322 legacy, 101 store, 61 runtime, 23 model).
- Selected Thread Sanitizer: 31 pass across native identity, metadata,
  materialization and sharing journal/plan suites; no reported race.
- Manifest and diff checks pass. Release IdentityLookupProbe builds.
- Fresh external functional probe: 22 rows (16-node source, columns/indexed
  conversion and point/audit/full checks), expected record counts and source
  protection pass. It runs the retained probe mode; the complete common writer
  mode is exercised by the local tests above. This is not timing acceptance.

Logs: `/tmp/graphevo-native-writers-{verified-full,verified-tsan,release,smoke}.log`.
Functional artifacts: `/tmp/graphevo-native-writers-smoke-20261029`. Its environment
records the parent checkout plus working changes; no benchmark speedup is claimed.
No generated stores/logs enter Git and no failed native mutation is replayed.

## Remaining gates

This verifies ordinary local operations on the candidate model, not actual
native-column private/shared assignment/import/recovery. Those hooks need physical
acceptance with the selected schema. Public openers still select the existing
model. Explicit protected-source conversion, activation/interruption recovery,
selective native query coverage and mandatory v1 local/cloud migration remain.
Read the [writer contract](../graphevo-2-native-identity-integration.md#common-writer-projection-maintenance).
