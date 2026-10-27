# GraphEvo 2 — cost and correctness experiment matrix

Status: active, 2026-10-27. Parent checkpoint: C03a `ea29ec9`, preferred B remains
`e2e53ab`. Work is isolated on `codex/v2-cost-experiment-matrix`; no integration,
merge, release-tag movement or final representation decision is authorized by
this matrix. Preserve intermediate commits/binaries so variants remain comparable.

## Variants and acceptance

| ID | Experiment / control | Measurement or assertion | Rejection / remaining boundary |
|---|---|---|---|
| M01 | B vs C03a split metadata | Reuse retained 564 local measurements and 473-test checkpoint | Listing gain alone does not complete C03 or sharing acceptance |
| M02 | Split metadata + binary top-level Data codec | Same eight-case Release matrix, 3 samples/operation; body read, directory bytes, RSS, query charges, seeds/observers | Keep old JSON and old attachment envelopes readable; reject truncated/future binary envelopes; nested/opaque values unchanged |
| M03 | M02 + descriptor-driven query property reads | Same matrix/budgets; scalar query/count/projection must no longer read unrelated file bytes | Full returned records, related predicates, sort/projection/aggregate/traversal dependencies, graph identity/membership, missing/null and pending edits must remain correct |
| M04 | Query/observation controls | Compare no-file 100/500 nodes, selected/other-graph files, 1/8 observers; same initial-read/patch/all-markers cycle | No notification suppression, shared cache or narrowed invalidation in this trial; retain cancellation, failures and per-handle lifecycle tests; no steady-state latency claim |
| M05 | Existing data / rollback | Read copied B and C03a fixtures with candidate; mixed-format SQLite reopen/replace/delete and complete backup tests | No writes to baseline fixtures, implicit conversion, downgrade promise or optional v1 data migration |
| M06 | Native owner/participant lifecycle | Fresh synthetic Development A/B fixture on iPad owner and XR other-account participant; invite, accept, exact export, participant insert, owner recovery, replacement, deletion, cascade, final distinct boundaries | Every stage once, bounded waits, protected transports; preserve pending intent/failed reports, never replay native assignment or reset cloud schema |
| M07 | Relaunch / independent recovery | Each native stage relaunches; peer observation checks exact IDs/metadata/digest/bytes and B unchanged/absent | Local save/setup is not an export barrier; no cloud-completion/offline/conflict guarantee |
| M08 | Full regression / build / CI | Final full macOS suite, manifest, independent Swift 6 Release consumer, diff/docs checks; iOS/macOS PR CI | Keep errors/limitations visible; no extra tests merely mirroring implementation |

M03 changes the experimental query materialization contract explicitly: preserve
full native node inventory, identities, membership, endpoint validation and
format-list validation. Read all properties for returned model-type records;
read referenced property dependencies for other nodes and for non-record
operations. Charge actual consulted raw payload before decoding. Skipped payloads
are not certified by an unrelated query; full record/file reads and native sharing
integrity keep complete validation. Budgets are not raised. A referenced file
body must still be charged/refused, and missing rows for requested encoded keys
must still fail. New success for unrelated four-large-file queries must be an
explicit runner expectation, never a silently ignored baseline failure.

## Execution discipline

Build/copy each immutable Release executable before running its matrix. Keep
source revision, binary/harness hashes, fresh external output directories and
all per-point outcomes. No build/tests during timed runs. Three-point synthetic
medians and sampled whole-process RSS are screening evidence, not production
thresholds. Native checks use the final candidate, so they do not establish an
intermediate variant's cloud acceptance. Keep accepted identity/ownership and
native framework synchronization; do not inspect private CloudKit bookkeeping.

Record outcomes and a proposed direction in a linked result before merging or
starting another redesign. C02 native indexed identities, C04 shared observer
work, representative production media/conflicts, coordinated alpha conversion
and mandatory v1 migration remain separate gates unless explicitly tested here.
