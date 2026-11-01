# TP01 — typed properties and native query feasibility, 2026-11-01

Status: local experimental evidence; no candidate model or query planner is
adopted. The [laboratory](../../../Experiments/TypedProperties/README.md) is an
external pinned export from `7164d8477d8684949a8f38811890de256dd876f2` (MF08/#130),
with a hashed local-only executable overlay. Shipping Sources/Tests/Package.swift,
independent consumers and CI are unchanged.

## Method and scope

The same synthetic Node/Property Core Data fixture compares the real
GraphValueCodec/GraphValueTransformer representation against typed authoritative
columns, first without value indexes and then with five compound indexes. It is
**not** a twelve-entity S03/full Graph API benchmark. Graph ownership/structural
validation, controls, query budgets/paging, observed-query work, real endpoints,
cloud transport and production attachment ownership are not timed or certified.

Final Release campaign: 1,000/10,000 ordinary nodes, three repetitions, three
variants, rotating variant order. Each of 18 fresh fixtures runs seed, pre-audit,
ten query operations in independent processes, mutation and restart/post-audit:
**252 passed process stages**, including **180 timed query stages**. Full audits
verify all properties, whitelist-kind edge cases, exact numeric bounds, binary
bytes, missing/null, cleared value columns on type changes, rollback, insertion,
property/owner cascade deletion, authored PH deletions and malformed-row refusal.

Operation time excludes store open and expected-result construction, but includes
fetch, decoding/evaluation, result materialization and assertions. OS/file caches
are uncontrolled. Seed includes value generation, insertion and one save.
Mutation includes reads, rollback, changes, save and full history retrieval; its
cost is not a pure single-record update. Only homogeneous numeric/ASCII query
fixtures are translated in the timed matrix. No public Graph speedup ratio or
production latency/size envelope follows from these microbenchmarks.

Environment: Apple Silicon macOS 27.0.1, Xcode 27.2 (27B52), Swift 6.4.2,
Release. Overlay SHA-256:
`a2162114722b6b7b389863a838e6c18a2fbdb7e6ce4531d5d7d1c8e6d8b0a5c0`.
Binary SHA-256:
`49ab208c75997825889d22d4287ae0df57377ff88e9902369536a1ecc767c646`.
Raw stores, logs, binary, pin and all successful samples remain external. The
working-tree dirty flag records the uncommitted experimental overlay, not
modified shipping sources. The committed overlay matches the measured hash.

## Final medians

Times are milliseconds. `count` and `compound` use owner SUBQUERY predicates;
`count-direct` counts matching property rows, while `compound-staged` first
selects owners from score properties, then filters their active properties.
Both alternatives require the audited one-property-per-owner/key invariant.
Whole-process high-water RSS includes harness, expected results and frameworks.
Closed seed bytes include PH and native auxiliary artifacts, not allocated blocks.

| Nodes | Operation | Envelope ms | Typed ms | Indexed ms |
|---:|---|---:|---:|---:|
| 1000 | seed | 228.385 | 159.382 | 182.598 |
| 1000 | equality | 33.228 | 0.996 | 0.662 |
| 1000 | range | 32.989 | 1.143 | 0.824 |
| 1000 | count | 33.553 | 1.147 | 2.137 |
| 1000 | compound | 52.952 | 1.259 | 3.229 |
| 1000 | sort | 34.428 | 1.426 | 1.028 |
| 1000 | prefix | 33.994 | 14.024 | 13.365 |
| 1000 | date | 34.521 | 1.156 | 0.828 |
| 1000 | unsigned | 33.596 | 1.167 | 0.828 |
| 1000 | count-direct | 33.682 | 0.658 | 0.346 |
| 1000 | compound-staged | 52.650 | 1.276 | 1.159 |
| 1000 | mutate | 21.976 | 20.613 | 21.401 |
| 10000 | seed | 2401.983 | 1665.095 | 1957.332 |
| 10000 | equality | 314.966 | 5.793 | 0.947 |
| 10000 | range | 321.295 | 6.880 | 2.251 |
| 10000 | count | 322.590 | 10.115 | 226.685 |
| 10000 | compound | 520.535 | 9.243 | 322.599 |
| 10000 | sort | 329.420 | 6.326 | 1.064 |
| 10000 | prefix | 312.492 | 20.075 | 16.645 |
| 10000 | date | 317.325 | 5.537 | 0.835 |
| 10000 | unsigned | 317.688 | 5.708 | 0.834 |
| 10000 | count-direct | 313.138 | 5.015 | 0.347 |
| 10000 | compound-staged | 510.836 | 6.693 | 4.228 |
| 10000 | mutate | 226.236 | 219.167 | 220.520 |

| Nodes | Variant | Closed seed bytes | Process peak RSS MiB (query maximum) |
|---:|---|---:|---:|
| 1000 | envelope | 2813952 | 19.7 |
| 1000 | typed | 1110016 | 15.7 |
| 1000 | indexed | 1933312 | 15.8 |
| 10000 | envelope | 27033600 | 73.8 |
| 10000 | typed | 9838592 | 19.8 |
| 10000 | indexed | 18206720 | 18.7 |

## Findings

1. Native scalar representation provides a substantial storage/execution benefit
   even without value indexes. At 10,000 nodes, equality is 314.97 → 5.79 ms,
   closed seed size is 27.03 → 9.84 MB and seed time 2.40 → 1.67 s. These are
   isolated representation measurements, not end-to-end Graph latencies.
2. Indexes improve selective property-first queries: equality 0.95 ms, sort
   1.06 ms, Date 0.84 ms and UInt64 0.83 ms. They cost approximately 85% more
   closed seed space and 18% more seed time than the unindexed typed variant,
   while remaining smaller/faster to seed than envelopes in this fixture.
3. Indexes do **not** uniformly help. Owner SUBQUERY count rises from 10.12 ms
   typed/unindexed to 226.69 ms indexed; two-key SUBQUERY rises from 9.24 to
   322.60 ms. These regressions were retained, not hidden in a selected average.
   The measured alternatives reduce indexed count to 0.35 ms and indexed
   conjunction to 4.23 ms. Schema and planner need to be designed together;
   blindly adding indexes or translating every descriptor the same way is unsafe.
4. Ordinary ASCII prefix queries improve, but remain proportional to their
   larger returned set (1,000 matches here). This does not validate general
   Unicode comparison or arbitrary graph traversals.
5. There is no duplicated scalar/shadow envelope. Bool/Int64/Double/Date use
   native columns; UInt64 uses exact padded text; Decimal uses exact text with
   no SQL numeric ordering; Data uses bytes; containers/opaque values retain
   envelopes. Special String and URL cases have explicit limits below.

Core Data diagnostic SQL on the synthetic indexed equality request confirms the
native WHERE contains property name, discriminator and integer value. No private
SQLite file was opened with SQLite APIs, and no index/query-plan certificate is
inferred solely from that log. Apple documents SQLite predicate evaluation and
its differences from Cocoa in [Persistent Store Types and Behaviors](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html).

## Semantic failures retained and candidate response

- Initial exporter failed before a run because its manifest insertion matched a
  product's target list; the anchor was corrected. No shipping manifest changed.
- Pilot 1 passed envelope checks but failed typed round-trip on the NUL-containing
  String. A separate minimal native-text diagnostic confirms Unicode scalars
  `[233, 0, 101, 769, 128578]` return as `[233]` after save/reset/fetch. The candidate
  stores these Strings with their existing envelope in bytes. It does not silently
  truncate or normalize. The [diagnostic source](../../../Experiments/TypedProperties/NativeTextDiagnostic.swift)
  reproduces the behavior on a fresh synthetic store.
- Pilot 2 passed envelope/typed checks, then failed indexed model construction:
  reassigning the existing index objects while appending indexes raised a Core
  Data duplicate-name exception. Build the complete list before assigning once.
- The corrected 100-node smoke passed all 36 stages. First full matrix passed
  216 stages; the query-shape follow-up passed 252 stages. These revealed the
  retained SUBQUERY regressions and motivate the final ten-operation matrix.
- SQLite native string equality did not match Swift canonical equivalence for
  decomposed `e + combining acute` versus composed `é` in all 24 final typed
  audits. Do not treat ordinary SQL text equality as a general replacement for
  Graph's String semantics. The benchmark uses ASCII text deliberately.
- The native Decimal diagnostic cannot distinguish/preserve the two selected
  nearby 38-digit values in all 36 final audits. The candidate's exact-text
  Decimal round-trip passes; numeric SQL comparison of that text is not offered.
- A further campaign added a relative URL with a base to the strict corpus and
  stopped on the **envelope baseline** audit: the current GraphValueCodec already
  flattens URL identity. Final audits report this separately (36 confirmations),
  rather than claiming success for it. The typed candidate explicitly rejects
  such URLs. This pre-existing limitation needs a separate lossless contract or
  explicit admission rule before production adoption; shipping behavior is not
  changed by the laboratory.

No failed fixture/mutation was reseeded or retried. Read-only diagnosis of the
first failure was separate from new campaign fixtures. Native code/fixture fixes
were followed by new external runs. Only the final campaign above uses the exact
retained final overlay hash; earlier passing campaigns retain their earlier pins.

## Direction and remaining work

Proceed to a focused native-property schema and eligible-query planner design.
Prefer exact single-authoritative storage and measured property-first execution;
select indexes from actual query shapes and keep explicit conservative evaluation
for unsupported semantics. Do not replace Graph's query semantics with whatever
SQL happens to return.

Before adoption: settle native scalar/opaque dispatch and corruption admission,
Unicode/null/mixed-type comparison, exact Decimal/UInt64 and URL contracts,
full real node/control/attachment behavior, budgets/pending views/cancellation,
PH identity/queue reconstruction, backups, v1 conversion, cloud round-trip and
physical independent recovery. The cloud format remains a separate logical
representation, but this experiment has not tested a typed-storage sync adapter.
Binary Data → attachment conversion remains consumer-owned. S03 is unchanged;
no new model, automatic conversion, beta or release gate is selected here.

Review checks source/fixture/result correspondence and unchanged shipping inputs.
The final checkpoint for those unchanged inputs remains #335. The laboratory
stays outside default CI; no repeated full CI is requested for this evidence-only
increment.
