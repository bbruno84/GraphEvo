# Descriptor-first query comparison — 2026-11-03

Status: bounded local comparison, not a remote integration, device or cloud gate.
See the [query-scope contract](../graphevo-2-descriptor-query-scopes.md).

## Matched inputs

Baseline is integrated #142, `d582d0aaf570ee2ca9a2b4cd368c1006b760b99f`.
Candidate shipping/test code is `954e6ba6da5ffd43ab02cf92954890b4fe0c1c23`.
Independent private copies use the same S04/Core Data configuration and converted
dataset: 1,822 native nodes, 1,820 application nodes, 486 records of the queried
type, 242 attachments with 109,091,048 original body bytes. Permanent attachment
bodies remain in Core Data; ordinary serialized values remain in their payloads.
Private stores, descriptors, manifests, records, traces and logs stay outside Git.

An external harness uses the actual public full-record query, with the same fixed
numeric predicate in both builds. Both Release builds enable testing for separate
constructor attribution; production source copies remain unchanged. Three serial
replicas per build run first-owner, warm and first-after-commit queries. The latter
follow real local commits. There are 66 measured queries across both builds.
Record/payload equality and cross-build fingerprints match for all 25 results.
Neither build reports a fallback. Host activity and OS caches are not isolated.

## Query results

| Scenario | Samples per build | Baseline median | Candidate median |
| --- | ---: | ---: | ---: |
| First query on a new owner | 3 | 264.46 ms | 41.95 ms |
| First query after commit | 9 | 267.19 ms | 42.85 ms |
| Warm query | 21 | 263.11 ms | 40.57 ms |

The generalized path is approximately six times faster in this workload. Opening
is essentially unchanged, approximately 614 versus 607 ms. Separately measured
Session versus query-source construction drops from roughly 150–160 to 8–10 ms.
Those constructor runs use separate scopes/copies: they are attribution evidence,
not an exact partition to subtract from the public query's total time.

| Diagnostic | Baseline | Candidate |
| --- | ---: | ---: |
| Resource-wide native candidates | 1,822 | 1,822 |
| Structural input records | 1,820 | 486 |
| Charged property/structural bytes | 51,549 | 19,076 |
| Logical steps | 18,304–18,305 | 4,034 |
| Explicitly instrumented engine fetches | 19 | 50 |
| Materialized complete results | 25 | 25 |

The baseline's single extra step follows a new diagnostic property outside the
queried type; the candidate's work stays unchanged. Native fetch counters do not
include every Core Data fault, admission or identity-validation request, and
their preparation coverage differs. They are not a total SQL-I/O comparison.

Median RSS immediately after the first query, with results alive and before
benchmark verification, is 38.97 versus 36.83 MiB. The process-lifetime high-water
mark through the query protocol is 42.92 versus 37.64 MiB; it includes launch,
opening, queries, commits and intervening verification, not a query-only peak.

## Limits and decision

Retain the generalized source and existing evaluator: the matched result is a
substantial improvement without adopting F's hardcoded second query engine.
Historical F's roughly 8–10 ms is not a matched comparison against this commit;
its prototype/cache/build context differs. Further latency tuning remains beta
measurement work, not a reason to replace the generalized engine now.

A separate SQLDebug run confirms native execution. Scalar-row fault SELECTs can
include ge2Bytes columns; that does not prove reads of the 242 attachment bodies.
No production body-read counter was added, and neither RSS nor charged-byte
diagnostics establishes zero native body I/O/materialization. Synthetic regressions
separately verify count/projection without registering unrequested body rows.
Full returned ordinary Data and serialized payloads remain validated and charged.

These measurements cover one local full-record scalar query. Sort/cursor,
related/traversal, pending/memory and error behavior derive from committed tests,
not this timing cohort. Broader datasets, devices, network, opening/listing,
memory envelopes and release acceptance retain their own gates.
