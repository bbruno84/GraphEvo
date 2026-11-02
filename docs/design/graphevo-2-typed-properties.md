# GraphEvo 2 — typed local properties

## Scope and delivery

The approved route has three checkpoints, each reviewed and integrated directly
into `codex/graphevo-2` before the next implementation branch:

1. **P01: S04 storage.** Adopt typed property columns in the package-only
   ContextManager, retain the existing memory query evaluator, and verify all
   persistence clients against the new representation.
2. **P02: hybrid Core Data query execution.** Translate safe source-order
   predicate prefixes, hydrate consulted fields and returned records, preserve
   observable errors and explicit budgets, and report the actual strategy.
3. **P03: runtime measurements and physical evidence.** Compare complete Graph
   operations against S03 with the same budgets, then test fresh CloudKit,
   sharing and recovery fixtures on owner/participant devices. No container reset.

This document defines P01. P02 and P03 remain open until their implementation and
recorded evidence exist. TP01 is experimental evidence, not production adoption.

## Model and opening

`GraphRuntimeSchema.typedProperties` identifies `GraphEvo.v2.schema.4` (S04).
It starts from the twelve-entity S03 model and retains graph/node identities and
history deletion preservation. Each of the three property entities gains optional
Int16 `ge2ValueKind` and `ge2ValueEncoding`, plus optional Bool, Int64, Double,
String, Date, UUID, URI and binary slots. Binary storage permits external files.
A typed application property has exactly one authoritative representation:
`object` is absent; kind and encoding are present; only its selected slot is set.
Null has no value slot. Reserved local metadata retains the old `object` storage.

Property indexes are `(name,node)` and `(name,kind,encoding,value)` for Int64,
Double, String, Date and UUID. Bool and binary are not indexed. Indexes are part
of S04 from its initial adoption rather than added repeatedly during planning.

Only the custom-sync ContextManager factory and internal v1 conversion target
select S04. Existing public current/nativeIdentity openers and historical native
mirroring remain unchanged; `nativeIdentity` still means S03. No public opening
API, automatic S03 conversion, model relabel or cloud reset is introduced.
Incompatible stores are refused without rewriting them. Mandatory v1 conversion
now produces S04; production-source/bootstrap/cloud cutover gates remain open.

## Values and keys

Model mapping first produces GraphRecord/GraphValue. Storage routing is internal:

| GraphValue | Representation |
| --- | --- |
| null | Kind only, native encoding, no slot |
| Bool | Native Bool |
| Int64 | Native Int64 |
| UInt64 | Exactly 20 zero-padded decimal digits in String |
| finite Double | Native Double, except negative zero |
| Decimal | Serialized; native decimal precision is insufficient |
| String | Native String, except strings containing NUL |
| Data | Raw binary, without a GraphValue envelope |
| finite Date | Native Date, except negative-zero reference interval |
| UUID | Native UUID |
| URL without base | Native URI |
| URL with base | Serialized URL components |
| Array, Object, encoded value | Serialized GraphValue envelope |

Negative-zero Double/Date and NUL strings use serialized envelopes. Nonfinite
numbers/dates and NaN Decimal are rejected. Preparation completes before edits;
patches clear the previous slot and remain inside the normal rollback boundary.
No implicit Data-to-attachment conversion is performed.

Literal keys containing NUL use a reversible reserved-prefix/base64 physical
name. Public logical keys are unchanged. Duplicate detection uses Swift String
equality, including canonically equivalent Unicode spellings. Escaped keys must
be canonical and decode to a key containing NUL; reserved logical keys remain
forbidden. Presence and explicit null remain distinct.

## Readers, PH, attachments and transport

Point reads, snapshots, queries, PH preparation, imports, migration workspaces and
publication use the same context-confined codec. No managed object or context
escapes. Reads reject invalid kinds/encodings, simultaneous slots, mixed old
application rows and mismatched envelopes rather than choosing a fallback value.
Query bytes are charged before envelope decoding; P01 keeps memory evaluation and
its previous body materialization contract. P02 changes that contract explicitly.

Attachments remain graph primitives with the existing ownership/digest rules.
Metadata-only access reads the GraphValue directly; raw attachment metadata Data
is not mistaken for another GraphValue envelope. Whole-store backup/restore must
include external binary resources, as before. Portable `.geb` ownership and
manifest contracts are unchanged.

Cloud still stores one `GraphEvoNode` CKRecord per primitive, with serialized
application properties and the existing CKRecord fields. Assets retain the CKAsset
route. Local typed columns are never projected as CloudKit property rows.
GraphValue envelope version 2 preserves recursive URL base/relative components;
version 1 remains readable and is emitted for values that do not need the new URL
case. Existing binary Data magic/version stays unchanged. No CloudKit record
format/session/transport-document version changes are introduced by P01.

## Remaining gates

P01 alone does not establish native predicate execution, performance acceptance,
physical S04 CloudKit/sharing/recovery, S03-to-S04 migration, or beta readiness.
P02 must preserve source-order errors, null/missing, identity/ownership inventory,
cancellation and budgets. Unsupported predicates are residual Swift evaluation;
there is no silent unbounded fallback. P03 must measure real runtime operations,
including setup/open, disk and whole-process memory, without treating TP01 toy
latencies as Graph benchmarks. Physical writers stay alive until independent peer
observation and recovered replicas start empty.

## P01 local review and checks (2026-11-02)

Local macOS checks pass 901 functions (331 legacy, 465 store, 76 runtime,
29 model). The existing coordinated suites now use S04 for PH, automatic sync,
conflicts, cloud payload/asset transport, sharing lifecycle, portable backup,
workspace/sealing/publication and v1 conversion. Historical public/mirrored S03
fixtures remain distinct. Selected iOS store/model suites pass; final focused
S04/URL/cloud-codec tests also pass. Both independent Swift 6 consumers pass on
their unchanged public opening paths. Manifest and diff checks pass.

Storage tests cover every GraphValue kind, 2 MiB binary data, Unicode and NUL
keys/strings, relative/based URLs, 38-digit Decimal, negative zero, type-changing
patch, null removal, reopen, PH discovery, rejected nonfinite write rollback,
old-schema refusal and malformed multiple-slot reads/export refusal. Agent
review corrected typed attachment metadata double-decoding, enforced the empty
legacy format list on S04 readers and removed serialize-on-read validation.
There are no remaining blocking P01 review findings. These checks are local or
injected; no physical S04 CloudKit result is claimed here.

P01 integrates via [PR #133](https://github.com/bbruno84/GraphEvo/pull/133).
Reviewed source `d9634b0aef46826bbc1229896cff00213364bd9c` passes full
[CI #346](https://github.com/bbruno84/GraphEvo/actions/runs/41403835359): macOS
suites and both independent consumers, 899 passed iOS functions/1012 invocations,
zero failures and one known legacy alias skip. Integration notes are docs-only;
shipping/test/consumer inputs remain identical to the checkpoint.
