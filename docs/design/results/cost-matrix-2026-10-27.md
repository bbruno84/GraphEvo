# Cost matrix result — native data, selective property reads and files

Date: 2026-10-27. Proposed direction: retain separate attachment metadata and
complete-content validation; prefer binary top-level Data plus descriptor-driven,
natively filtered property reads as the next candidate for review. Do not freeze
the schema or integrate automatically. Read the [matrix](../graphevo-2-experiment-matrix.md),
[C03a result](c03a-attachment-metadata-costs-2026-10-27.md) and
[consolidation gates](../graphevo-2-consolidation.md).

## Executed variants and outcomes

| Matrix row | Outcome |
|---|---|
| M01 — B / split metadata | Reused C03a's retained 564 measurements and checkpoint; additional split-format controls below |
| M02 — binary top-level Data | Full eight-case matrix plus four-case confirmation; much faster complete reads and lower large-file storage/RSS, with a small-file storage trade-off |
| M03 — property dependencies | Full matrix/confirmation; unrelated large-file queries succeed at the unchanged allowance, but native property faulting still costs memory |
| M03b — native row filtering | Full matrix/confirmation and a native-transformer probe; selected property rows exclude unused bodies before value access; strongest query/RSS result |
| M04 — observations / controls | 102 measured one/eight-observer cycles across variants; original notifications, cancellation and lifecycle retained; no shared-observer engine introduced |
| M05 — existing data | Candidate reads/lists/queries protected copies of actual B and C03a SQLite fixtures; mixed logical attachment formats retain replacement/reopen/cascade behavior; no conversion on open |
| M06 / M07 — physical sharing / relaunch | Fresh owner iPad / different-account XR lifecycle passes all 14 stages, plus two final M03b read-only query/count/projection stages; exact bytes/metadata, assignment and B isolation checked |
| M08 — regression / build | Final 477 local tests and 18 targeted sanitizer tests pass after fixture compatibility corrections; final PR CI tracked separately |

The new local campaign contains **946 validated measurements**: three full
matrices of 182 points (M02, M03, M03b), and four confirmations of 100 points
(split, M02, M03, M03b). Three processes per non-seed operation, fresh fixture
per campaign, identical sizes and budgets. The 27 property-budget refusals in
split/M02 are expected. M03/M03b success on unrelated large files is explicitly
selected/recorded by the runner; unexpected errors remain fatal. No measured
fixture was reset or retried after a failure. Builds/tests did not overlap timed
campaigns. Seeds are single observations per fixture, not distributions.

## Query and read direction

The table uses independent confirmation medians, in milliseconds. Four-large-file
query is shown at 128 MiB for all variants so the comparison includes a successful
baseline. The default allowance remains 32 MiB.

| Operation | Split + JSON | M02 binary | M03 dependencies | M03b native filtering |
|---|---:|---:|---:|---:|
| Four 10-MiB files: unrelated query, 128-MiB allowance | 210.92 | 48.56 | 44.93 | 28.31 |
| Same query: sampled whole-process peak MiB | 124.2 | 87.5 | 57.4 | 17.1 |
| Same query: charged bytes | 56,827,366 | 41,970,194 | 25,010 | 25,010 |
| Default-budget unrelated query | Refused | Refused | 45.53 | 28.87 |
| Read one 10-MiB attachment completely | 70.87 | 26.13 | 26.12 | 25.87 |
| Four 1-MiB files: unrelated scalar query | 51.66 | 31.17 | 31.29 | 28.15 |
| Four 1-MiB files: eight-observer cycle | 528.61 | 381.30 | 381.32 | 363.48 |
| Same observer cycle: sampled peak MiB | 105.0 | 79.2 | 48.0 | 23.3 |
| No files, 500 nodes: complete-model query | 131.27 | 132.85 | 132.34 | 132.82 |
| No files, 500 nodes: eight-observer cycle | 1864.69 | 1667.00 | 1725.24 | 1707.80 |

M03b's first full matrix independently reports 28.08 ms / 17.2 MiB on the raised
large-file query and 28.10 ms at the default allowance. Its eight-observer cycle
with four small files is 399.92 ms / 23.8 MiB; timing varies more than the memory
result. No-file complete-model queries remain around 132 ms because full model
payloads/inventory are deliberately retained. This is not C02's indexed identity
solution or C04's shared-work implementation. The observer metric includes all
initial reads, a patch and every refreshed marker, not event/frame latency.

M03b uses complete descriptor property dependencies, including related predicates,
sorts, projections and aggregates. Complete model-type results still snapshot
all fields. Full native candidate inventory, graph membership, format lists and
endpoints remain checked. Referenced raw payload is charged before value decoding;
explicit body references still exhaust a small allowance. An unrelated query no
longer certifies skipped payloads; complete reads and sharing integrity do.
A unique native-transformer probe proves a skipped body is not transformed while
a requested malformed legacy value fails visibly. Capture surrounds lookup and
execution, preventing decoder failure from becoming an absent property.

## Storage and remaining costs

Binary storage is **not uniformly smaller** in these native store fixtures.
Confirmation apparent seeded directory sizes:

| Fixture | Split JSON bytes | M03b binary bytes |
|---|---:|---:|
| Four 1-MiB files | 6,224,650 | Approximately 9.7 MB |
| One 10-MiB file | 14,664,596 | Approximately 11.0 MB |
| Four 10-MiB files | 57,379,020 | Approximately 42.5 MB |

The four-small-file growth repeats across binary variants/campaigns. Retain it as
a decision trade-off; do not explain it through unverified private storage rules
or claim uniform allocation savings. These are apparent directory totals after
close, including native/application artifacts, not physical allocation or proof
of external binary placement. Production media and intermediate sizes need a
separate size/storage sweep before freezing the representation/envelope.

Metadata listing remains faster than B, but this trial does not apply M03b's
native property-row filtering to the separate list adapter. Four large-file
listing is 25–29 ms / about 57 MiB; full reads buffer complete data. No streaming,
progress, eviction/download selection or hard memory guarantee is introduced.

## Physical native framework evidence

Run `4E92A3E6-7E07-4609-9117-12218D796BFE`, authorized Development container
`iCloud.com.valerioburiani.GraphCKDemo`. Owner: iPad di Bruno. Participant:
iPhone XR with the other iCloud account. Disposable signed demos only; original
demo checkout and historical fixture stores were not modified. Native probe
procedure/source is [retained here](../../../Experiments/CostMatrixNativeProbe/README.md).

All stages pass: seed, identity, invite, accept with exact export, participant add,
owner observe-add, participant replace, owner observe-replacement, independent
replacement export, participant delete, owner observe-deletion, owner cascade,
participant observe-cascade and owner-final-boundary. Replacement metadata is
protected/run-bound and compared exactly across accounts, as well as original
bytes, digest, identity/owner and revision changes. The added file and every
owned native detail map to A's share. B's exact control survives on owner and is
absent on participant. Final A/B boundaries are both non-nil and distinct.

The full lifecycle uses M02's binary format with M03 query implementation; M03b
changes only query read materialization. After installing the M03b build, two
fresh read-only stages independently verify typed query/count/metadata projection
under 32 KiB, empty A and isolated exact B content. No lifecycle mutation was
replayed to test the final reader.

One owner observe-deletion launch produced no initial report while its process
remained present, device unlocked and no matching crash report appeared. The
launch evidence was retained. Explicit termination and relaunch of that **read-only**
check completed it; the driver then completed cascade/final checks. No deletion,
assignment, invitation or replacement was resubmitted. The console's later signal
9 is the driver's deliberate next-stage termination, not evidence of a crash.
This isolates a harness/device launch limitation without claiming its root cause.
Every subsequent launch is a process reopen. No offline, concurrent conflicting
writers, account loss, interrupted assignment or global cloud-completion claim
is added by this successful serial lifecycle.

## Regression, compatibility and remaining gates

Final local tests after fixture corrections: 322 legacy, 60 runtime, 72 store, 23 model:
**477 pass**. Targeted Thread Sanitizer: **18 pass**, no reported race. Coverage
includes complete-model fields, missing/null, related/negated dependencies,
projection/aggregate/traversal, explicit-body budget refusal, requested missing
encoded values, native decoder poisoning, pending edits, multiple stores,
observation/cancellation and existing attachment lifecycle/backup tests.
Root manifest, independent Swift 6 Release consumer, signed iOS build, Python
syntax, diff and documentation checks are included.

Swift 6.1 CI found test-fixture transfer assumptions accepted by the newer local
SDK/compiler. An initial explicit-Sendable change was insufficient for contexts
that are non-Sendable in the older SDK. Final fixture setup uses the native async
container callback's context parameter instead of capturing a context across
isolation. No production isolation/Sendable rule is weakened. A missed fixture
constructor during that test-only edit was caught locally before acceptance;
failed logs remain retained. The corrected local suite and sanitizer selection pass again. PR #81 final
CI remains a separate acceptance check; the earlier CI build failures are not
silently treated as passes.

Existing B single-envelope/JSON and C03a split/JSON fixtures are read from new
whole-directory copies, never modified in place. The binary codec retains JSON
reads, version/length checking and nested/opaque semantics. Legacy attachment
replacement retains its logical envelope; writes can use the new outer codec.
There is no automatic conversion, downgrade support or completed v1 migration.

The direction proposed for review is M02 + M03b, retaining the accepted attachment
identity/exclusive owner and full native synchronization ownership. Prioritize
representation/storage envelope validation and selective native identities next.
Use measured observer gains before deciding whether C04's additional shared-work
complexity is needed. Keep storage growth, full list/read memory, real media,
offline/conflict/account recovery, coordinated alpha conversion and mandatory v1
local/cloud migration open. No schema freeze, beta declaration or automatic merge.

## Reproduction and retained artifacts

Immutable binaries: `/tmp/graphevo-matrix-binaries`; M02 `46f7599`, M03 `8698d66`,
M03b `6cf8b82` runtime code. Later fixture/documentation-only commits do not change
measured library code. Exact executable SHA-256:

- M02: `c784815fd38b2fd26156efc880160702cd0ed2e66e1c5d7ff7e7653b38854e6b`
- M03: `b0249c3e92bd4cc54118961eaef5e2346dcc3061624595e40d79cd4b581bb490`
- M03b: `0a7fce147715439a612c1539b5054166b1e3a11750921f00610d405b2467f3c8`

Full matrices: `/tmp/graphevo-matrix-{m02,m03,m03b}-20261027`; confirmations:
`/tmp/graphevo-matrix-{split,m02,m03,m03b}-confirm-20261027`. Each contains
per-point logs/JSON, fixture, harness hashes and environment. The runner records
the checkout revision, not historical binary provenance; use the hashes above.
Old-data copies/checks: `/tmp/graphevo-matrix-old-data-checks`. Native lifecycle
reports/transports: `/tmp/graphevo-matrix-native-20261027` (protected outside Git),
plus `/tmp/graphevo-matrix-query-{owner,peer}.txt`. Final iOS build/source:
`/tmp/GraphEvoMatrixSelective{Demo,Build}`. Keep raw stores, credentials,
identity/invitation data, tokens and diagnostic logs outside Git.

Synthetic data, uncontrolled OS/SQLite caches/load, single seeds and sampled
whole-process RSS limit conclusions. Retain first/confirmation outcomes and
trade-offs; no timing threshold or arbitrary workload guarantee is inferred.
