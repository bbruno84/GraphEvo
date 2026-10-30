# M2b.1 data-format contracts — validation (2026-10-30)

Scope: [detached format contracts and normal-store refusal](../graphevo-2-data-formats.md),
not public versioned-store activation, v1 conversion or CloudKit admission.
Native S01 attributes, indexes, identifiers and opening defaults are unchanged.

## Evidence

- Five model tests distinguish nil, zero and explicit formats; reject invalid
  declarations/negative versions; check readability before consumer decoding;
  admit explicitly compatible old/new read formats without authorizing writes;
  validate current-format serialization and preserve versions/unknown fields in patches.
- Seven store behavior tests cover both normal native schema selections for failed
  insert rollback and pre-native shared refusal; SQLite/in-memory versions on all
  three node kinds; point/missing/query/count/projection/traversal/file/mutation/
  integrity refusal; cross-graph conservative blocking and control-only access;
  observable failure/explicit producer repair; pending metadata preceding malformed
  payload decoding with rollback; compatible undeclared reads without typed write
  permission; two local SQLite stores with an unrouted versioned secondary row;
  and format refusal for non-record queries before property interpretation.
- Existing fourteen M2a behavior tests still validate native publication, recovery,
  interruption and no callback replay. The structural-refusal test additionally
  rejects consumer replacement of version metadata. The manager remains responsible
  for stamping the prepared target; the existing archive format is retained.
- The independent Swift 6 ModelConsumer compiles and exercises public format aliases,
  declared detached serialization and its previous typed persistence checks.

The complete package suite passes **567 tests**: 331 legacy, 142 store, 66 runtime,
28 model. Parameterized cases include both persistence backends and all node kinds;
the number of cases is not represented as additional test functions. Manifest,
diff formatting and changed-document relative links are checked before publishing.

Initial compilation exposed the added GraphStoreError case missing from its
LocalizedError switch; the diagnostic was implemented without changing test
expectations. Review added explicit query-definition format policy so count,
projection and aggregate cannot bypass it; earlier complete 565/566-test runs
preceded the additional paired-store/non-record-query cases. Raw logs remain
external under `/tmp/graphevo-m2b-*`; no stores,
native metadata injections, prepared archives, journals or raw logs are committed.

## Limits

Normal versioned persistence deliberately remains refused. The preflight blocks
the whole resource group, including other graphs, until the shared registry and
dependency-scoped policy are implemented. It adds native scan work to S01 point
reads; no performance threshold or previous indexed-timing equivalence is claimed.
Model declarations are consumer promises, not automatic content conversion.

Native metadata injection and repair model already-present local state. Two local
stores are not a native private/shared CloudKit test. No import interceptor, cloud
pause, cross-device acceptance, global synchronization barrier, production backup
policy or source cutover is established. Keep M2b activation and M3–M6/PA08 open.
Exact-head CI and review are required separately before merge.
