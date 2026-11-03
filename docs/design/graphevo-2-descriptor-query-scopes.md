# Descriptor-first local query scopes

Status: candidate on `codex/v2-descriptor-query-scope`, directly from integrated
#142. Read with [controlled access](graphevo-2-controlled-store-access.md),
[A7](graphevo-2-queries.md) and [P02](graphevo-2-typed-properties.md). No native
schema, stored envelope, cloud document or public signature changes.

## Query inputs and integrity

The non-mirrored S04 native adapter keeps `GraphTypedQueryExecution` and its
evaluator. A query-local source replaces the full mutation Session inventory.
Queries do not run resource-wide structural, membership or identity audits.
`validateIntegrity()` remains explicit; opening, migration and mutation admission
keep their own validation. A successful query does not certify the rest of a store.

Candidate allowance still counts every native node row in the resource group:
controls, other types/graphs, staged rows and damaged routing included. Count is
checked once before selecting inputs. Missing/misdirected native identity columns
can hide unrelated rows; discovering that damage belongs to the audit. Returned
identities, owned metadata and direct endpoints are validated before output.
Traversal validates origins and returned visits even when no edge is traversed.
Count/projection/aggregation do not become complete application-integrity checks.

The structural domain follows the descriptor. Ordinary operations select their
model kind and canonically equal type. Related predicates and traversal also
select Entity headers and the relationship/action kinds and optional edge types
named by their relations, including nested relations. They load this bounded
structural domain, not a lazy per-frontier SQL walk. Only query-required topology
is validated; an unrelated edge kind/type is not audited by an Entity query.

Fresh SQLite scopes project native identity/type/date and tag/group headers
without building all application Node facades. Logical type and key identity use
Swift canonical equality; distinct physical UTF-8 spellings remain available to
native predicates. Pending and in-memory views instead use managed inputs to
preserve inserts, edits and deletions, without invoking a full Session audit.
Their managed-fetch cost is not the fresh SQLite performance claim.

## Consulted properties and allowances

Property headers load for literal keys actually consulted. Full returned records
enumerate/decode all their own application fields; projection reads its selected
keys. Ordinary Data, arrays, dictionaries and Codable/opaque values keep their
encoding. Attachment bodies remain in Core Data.

The existing translator/evaluator retains source-order AND-prefix translation,
exact scalar categories, missing/null, Unicode, sorts, cursors and residual
operations. Consulted scalar representations are validated before selecting
winners: malformed/incompatible losing values cannot disappear behind SQL.
An earlier identity guard can narrow consultation; a later guard cannot hide an
earlier property error. Unsupported cases keep the same query source and budgets,
without restarting a whole-resource audit.

One work counter covers source/header visits, native preparation, sort/merge,
result validation and residual evaluation. Value bytes are charged before decode.
Cached values already charged by a filter/sort are not charged again in hydration.
Candidate count is not consumed twice; partial attempts never reset steps/bytes.
No partial output escapes failure. SQLite reads stay pinned; memory reads keep
the runtime writer-gate contract. Nothing survives its native scope.

On this path, `scopedNodes` describes the descriptor's structural domain rather
than every application node in its graph; `nativeCandidates` stays resource-wide.
Native fetch diagnostics count explicitly instrumented source/value operations;
admission and targeted identity validation can perform additional Core Data work.
These are not total SQL-I/O, elapsed-time or process-memory bounds. Historical
S03/current and mirrored query paths keep their previous adapter contracts.

## Verification

Regressions distinguish local query corruption from explicit audit, retain the
resource allowance despite hidden routing, validate losing scalar/source-order
behavior, pending insertion, canonical types, descriptor-specific topology,
traversal origins and scalar count without application facades/unrequested bodies.
Existing P02 parity, payload budget, sorting/paging and capacity cases remain.
Private F's narrow timings do not establish the generalized path's performance.
Matched performance measurement and reviewed integration remain pending.

Local checks on `954e6ba6da5ffd43ab02cf92954890b4fe0c1c23` pass 980 macOS
functions (331 legacy, 527 store, 92 runtime, 30 model), 23 focused iOS 18.5
Simulator query functions with no failures/skips, both Swift 6 consumers and
manifest/diff checks. The focused set includes the unchanged capacity case.
This is not a remote checkpoint, physical-device or cloud acceptance result.
