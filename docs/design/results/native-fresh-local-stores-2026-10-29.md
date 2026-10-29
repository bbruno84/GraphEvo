# Fresh native local stores — acceptance (2026-10-29)

Status: explicit local alpha schema option after M13. No conversion of earlier
alpha stores. Default/current and mirrored schema selection are unchanged;
fresh native private/shared acceptance is the next increment.

## Public behavior

`GraphDatabase.open(at:schema: .nativeIdentity)` and
`inMemory(schema: .nativeIdentity)` create fresh native-column stores and reopen
compatible stores. The catalog starts empty. New graph controls are activated only
when newly allocated, empty and unstaged, with valid native projections. A distinct
public alpha marker refuses historical prototype files even when model hashes
match. Current-model incompatibility is rejected without erasure or migration.

GraphNativeIdentityAccess is the common persistence resolver. The old experiment
is a wrapper retaining its original marker/model/conversion helpers. Production
opening calls create-only activation, never backfill. Native point hits retain
target/reference validation; misses audit same-view routing and identities.
Common mutations/queries check the graph protocol. Scoped snapshots validate
consulted native projections, including bounded query failures/recovery. Only
explicit historical backfill can inspect unprojected source snapshots.

Queries still use the documented full bounded inventory plus selective property
materialization. No native SQL filtering strategy, uniqueness or global sync
certificate is introduced. Metadata-only file listing and complete storage
integrity are distinct operations.

`validateIntegrity(of:)` returns selected application-row count after identities,
structure and complete stored-payload/file checks. It supports both public
schemas, does not invoke app model decoders and has no query-budget/whole-memory
bound. It is not domain validation, another replica's state or import completion.

## Local checks

- Full suite: 511 pass (322 legacy, 105 store, 61 runtime, 23 model).
- Selected Thread Sanitizer: 30 pass across fresh/native/materialization and
  journal/plan suites; no reported race.
- External public-product Swift 6 Release ModelConsumer passes native SQLite
  creation, model insertion, integrity, typed query, Combine and reopen. No
  test/package access is used by that consumer.
- Existing prototype conversion/backfill, pending edits, duplicates, unrouted and
  staged cases, native body exclusion and wide actions still pass after extraction.
- New public tests cover fresh SQLite/memory, empty catalog, independent graphs
  and leases, files and reopen, current/prototype refusal with original reader
  preservation, current-schema integrity, missing graph and native corruption
  surfaced by point/query/integrity/observation with injected producer recovery.
- Manifest and diff checks pass. Native model factory remains fresh per owner;
  default factory and resource URL resolution are unchanged.

Logs: `/tmp/graphevo-native-fresh-{full,tsan,consumer}.log`; intermediate
initial/access/selected logs retain focused checks. All stores are new temporary
fixtures. No application/device/cloud store was reset and no raw store/log enters
Git. No performance envelope or new timing comparison is claimed.

## Reviewed baseline and remaining work

#87/#88 exact heads passed macOS/iOS CI (`40850126842`, `40850800362`), were reviewed
and merged at `7335b66` / `199d56d` in the consolidation parent. Their merges preserve
reviewed trees. The v2 integration branch and alpha.8 tag are unchanged.

Fresh native private/shared initialization, actual assignment/import/leave/access
recovery and physical cross-user evidence remain before mirrored native selection.
The public local option does not prove a new local path has empty cloud data.
Mandatory v1 migration and beta compatibility remain separate; M13 removes
alpha conversion/downgrade/recovery tooling from delivery gates.
