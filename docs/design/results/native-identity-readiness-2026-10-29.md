# Native identity readiness — local result (2026-10-29)

Status: first integration prerequisite, PR #86 stacked on reviewed #85. Native
negative lookup now audits identity inventory before returning nil. Default
public schemas/openers, model hashes/index configuration, CloudKit assignment
and alpha.8 are unchanged. This is not completed native-schema adoption.
Read the [integration contract](../graphevo-2-native-identity-integration.md).

## Validation and scope

- Final local suite: 504 pass (322 legacy, 98 store, 61 runtime, 23 model).
- Selected Thread Sanitizer: 16 pass (nine native identity, six materialization,
  one query cancellation); no reported race.
- Manifest, Python AST, diff and Release build pass.
- Known staged rows in the selected graph block absence with pendingNativeOperation.
  A native resource-wide readiness pass also rejects unrouted rows missing both
  raw and native graph IDs; otherwise they would disappear from every graph filter.
- The graph audit cross-checks raw/native identity, membership/format inventory
  and exact backing-row coverage. Missing/misrouted columns, incomplete activation,
  duplicates, pending edits and rollback retain explicit checks.
- A unique native transformer poison probe proves zero body transformations for
  audit/valid negative reads and failure when that body's node is requested.
  Corrupt typed body bytes also remain separate from metadata identity validation.
- Full integrity adds complete application/endpoint/attachment-owner checks.
  Neither audit nor full integrity is a CloudKit import-completion certificate.
- Resource readiness exposed two older tests that backfilled only one of two
  graphs. Their valid-absence setup now backfills both. Explicit partial-resource
  tests retain targeted hits and reject negative reads until readiness; production
  guards were not weakened. The intermediate failed probe log is retained.

Local logs: `/tmp/graphevo-native-readiness-{audited-full,final-tsan,release}.log`;
intermediate native/routing/resource probes also remain under that prefix.
The initial narrower audit was extended before timing to catch completely
unrouted rows. No failed native seed/conversion stage was replayed.

## Focused Release run

New owned temporary sources: 500 Entity nodes plus an edge/action; and 100 Entity
nodes plus an edge/action and one 10-MiB attachment. Source is closed and copied
before explicit conversion into columns/indexed stores. Conversion checks exact
sample fingerprints (kinds, IDs, endpoints, values and file bytes) and unchanged
original SQLite hash. No application/device/cloud source is opened. This remains
alpha-to-prototype conversion, not complete v1 or paired CloudKit migration.

Three fresh-process repetitions per operation retain 120 rows: six seed/conversion
rows and 114 operation rows. Metadata audit/full validation must report the exact
expected application-row count. No local build/test ran during timing. Operation
latency excludes opening; total process time and final RSS are separately recorded.
Final RSS is not a sampled peak. OS caches are uncontrolled and three samples of
two synthetic cases do not define a product envelope.

`full` denotes the current public adapter's full-inventory point operation, which
validates routing/format metadata and reads only the requested record body; it is
not full-graph payload integrity. Native hits remain targeted and have a different
validation scope. Native misses now add resource readiness and same-view graph
identity inventory. `audit` is metadata-only; `validate` adds all graph payloads.

| Case | Variant | Operation | Samples | Median ms | Min–max ms |
|---|---|---|---:|---:|---:|
| flat-500 | plain | seed | 1 | 3115.383 | 3115.383–3115.383 |
| flat-500 | columns | convert | 1 | 817.747 | 817.747–817.747 |
| flat-500 | indexed | convert | 1 | 817.600 | 817.600–817.600 |
| flat-500 | full | read | 3 | 46.230 | 46.137–46.788 |
| flat-500 | columns | read | 3 | 2.937 | 2.928–2.945 |
| flat-500 | indexed | read | 3 | 2.558 | 2.452–2.683 |
| flat-500 | full | read-edge | 3 | 47.316 | 46.179–47.351 |
| flat-500 | columns | read-edge | 3 | 3.858 | 3.681–4.095 |
| flat-500 | indexed | read-edge | 3 | 3.496 | 3.446–3.751 |
| flat-500 | full | read-action | 3 | 46.639 | 46.399–49.910 |
| flat-500 | columns | read-action | 3 | 3.923 | 3.869–4.591 |
| flat-500 | indexed | read-action | 3 | 3.538 | 3.523–3.601 |
| flat-500 | full | missing | 3 | 46.917 | 45.942–48.030 |
| flat-500 | columns | missing | 3 | 51.738 | 51.198–52.234 |
| flat-500 | indexed | missing | 3 | 51.548 | 51.544–52.310 |
| flat-500 | full | patch | 3 | 48.499 | 46.830–48.982 |
| flat-500 | columns | patch | 3 | 4.003 | 3.922–4.101 |
| flat-500 | indexed | patch | 3 | 3.631 | 3.404–3.885 |
| flat-500 | columns | audit | 3 | 51.594 | 51.569–52.614 |
| flat-500 | indexed | audit | 3 | 51.006 | 50.189–52.667 |
| flat-500 | columns | validate | 3 | 178.101 | 175.552–180.416 |
| flat-500 | indexed | validate | 3 | 178.035 | 176.339–183.002 |
| file | files | seed | 1 | 706.450 | 706.450–706.450 |
| file | columns | convert | 1 | 362.784 | 362.784–362.784 |
| file | indexed | convert | 1 | 363.013 | 363.013–363.013 |
| file | full | read | 3 | 11.563 | 11.259–11.592 |
| file | columns | read | 3 | 2.901 | 2.633–3.004 |
| file | indexed | read | 3 | 2.526 | 2.409–2.630 |
| file | full | read-edge | 3 | 11.013 | 11.002–11.070 |
| file | columns | read-edge | 3 | 3.752 | 3.649–3.965 |
| file | indexed | read-edge | 3 | 3.612 | 3.596–3.712 |
| file | full | read-action | 3 | 11.205 | 11.055–11.256 |
| file | columns | read-action | 3 | 3.647 | 3.382–3.763 |
| file | indexed | read-action | 3 | 3.411 | 3.410–3.576 |
| file | full | missing | 3 | 11.029 | 11.012–11.105 |
| file | columns | missing | 3 | 13.609 | 13.578–13.661 |
| file | indexed | missing | 3 | 13.563 | 13.509–14.123 |
| file | full | patch | 3 | 12.289 | 12.207–12.630 |
| file | columns | patch | 3 | 11.708 | 11.689–12.832 |
| file | indexed | patch | 3 | 12.045 | 10.785–12.085 |
| file | columns | audit | 3 | 13.849 | 13.469–19.815 |
| file | indexed | audit | 3 | 18.457 | 16.760–18.699 |
| file | columns | validate | 3 | 60.147 | 59.992–61.036 |
| file | indexed | validate | 3 | 60.993 | 59.113–61.325 |

## Assessment

On 500 nodes, indexed Entity/Relationship/Action hits remain about 2.56/3.50/3.54 ms;
Entity patch is about 3.63 ms. Full-inventory point controls are about 46–48 ms,
but these are not equivalent whole-inventory validation guarantees on a hit.

Safe indexed absence is about 51.55 ms (range 51.54–52.31), versus 46.92 ms for the
current adapter. This is a deliberate cost increase relative to the original
fast-but-weaker C02b missing result. Do not reuse the old missing timing as the
new absence guarantee. Metadata audit is about 51.01 ms; full payload validation
about 178.03 ms. No cached audit or UUID repair was used to improve costs.

In the file fixture, indexed hits remain about 2.5–3.6 ms. Native absence is about
13.56 ms versus 11.03 ms control. File-bearing owner patch remains about 12 ms:
no new file-patch speedup is claimed. Standalone indexed audit varies 16.76–18.70 ms
and columns audit 13.47–19.82 ms; retain that variation instead of inferring a
uniform index benefit. Full validation is about 61 ms. The native poison test,
not a timing difference, establishes unused-body exclusion.

## Provenance and remaining work

- Clean measured source: `1dbd1264a64876b2665b21480067ca77e71bef99`.
- Binary SHA-256: `531b8d374a9f7dc4369bb81db086314cfcbd5ce68dce2e57788f312907def59b`.
- Runner SHA-256: `b8b9c9b54d4d28852dc1dd452b9b231a1c8affef21cd2351b0a48da3b488c106`.
- Host: `macOS-27.0.1-arm64-arm-64bit-Mach-O`.
- Binary: `/tmp/graphevo-c02-binaries/native-readiness-1dbd126-IdentityLookupProbe`.
- Complete external artifacts: `/tmp/graphevo-native-readiness-20261029`, including
  source/copies/destinations, metrics, environment, summaries and per-stage logs.
  No generated store/log enters Git.

#84/#85 reviews have no blocking code findings; exact-head macOS/iOS runs
`40828821638`/`40830758724` passed. Both were marked ready; neither was merged in
this increment. #86 CI remains separate and must be checked before merge.

All-writer projection maintenance, explicit protected-source conversion/activation
and interruption recovery, native private/shared import/conversion, selective query
coverage and mandatory v1 local/cloud migration remain open. The metadata audit
is scoped to one context/local view with resource-wide native route readiness;
it neither certifies global uniqueness nor another replica/account/cache state.
No default schema selection, beta entry or integration/tag promotion is implied.
