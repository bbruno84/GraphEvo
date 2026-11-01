# TP01 — scalar property storage and native query feasibility

Local-only experiment, based on integrated MF08/#130. No shipping source, native
S03 model, public opener, cloud payload, migration format or CI target changes.
The result informs a later implementation decision; the candidate is not adopted.

## Question and variants

Can native value columns remove the serialization/evaluation cost of scalar
property queries while preserving the GraphValue whitelist?

| Variant | Authoritative property value | Indexes |
|---|---|---|
| envelope | Current package GraphValueCodec bytes inside the real GraphValueTransformer transformable | Node ID and property (name, owner) |
| typed | Discriminator and one native value column, or opaque bytes for complex values | Same base indexes |
| indexed | Same typed representation | Adds (name, discriminator, value) for integer, Boolean, Double, Date and text |

The shared synthetic Core Data model has Node/Property entities and a separate
small Decimal diagnostic entity. It does **not** alter or manipulate Graph's
Managed* classes, imitate the twelve-entity model or run the Graph query planner.
Each fixture represents one store/graph, with node-kind labels cycling across
three values. It does not model actual Relationship/Action endpoints, controls,
identity auditing, attachments, observation, native PH processing or cloud sync.
Both envelope and typed paths use the same synthetic shape and fixture data;
this isolates representation, rather than comparing full Graph against a toy
query and presenting the ratio as an end-to-end speedup.

## Run

```sh
python3 Experiments/TypedProperties/prepare.py /tmp/graphevo-tp-export-new
swift build -c release --package-path /tmp/graphevo-tp-export-new --product TypedPropertyProbe
python3 Experiments/TypedProperties/run.py \
  --executable /tmp/graphevo-tp-export-new/.build/release/TypedPropertyProbe \
  --output /tmp/graphevo-tp-run-new
```

Export/output must be new external directories. The exporter archives shipping
HEAD and hashes the local overlay; the runner checks its hash and records the
binary SHA-256, pin, environment, dirty state, raw logs and every successful
sample. Neither seeds nor failed mutations are retried. Retain failed outputs
and diagnose before starting a new fixture. Use only generated laboratory stores.
No application, device or CloudKit container is opened. Generated stores/logs/
binaries and signing details are never committed.

The default matrix has 1,000/10,000 ordinary nodes, three repetitions, three
variants and ten query shapes. Each node has eight properties, plus explicit
null on every third node; absence on the other nodes remains absence. A sentinel
node covers every GraphValue kind, Int64 bounds, UInt64 bounds, high-precision
Decimal, Unicode/NUL, a literal punctuation key, fractional Date, UUID, URL,
64-KiB Data, containers and opaque encoded data. No binary becomes an attachment.

`swift Experiments/TypedProperties/NativeTextDiagnostic.swift` separately
reproduces the NUL text round-trip on a new temporary native store.

Each repetition seeds a fresh store. Variant order rotates; every query executes
in a new process. Audits before measurement and after a separate mutation process
check **all** expected properties, node identities and sentinel values. Mutation
covers rollback, type change with clearing old columns, null, property insertion/
delete, owner deletion/cascade and authored PH deletion visibility. Negative
checks reject unknown discriminator and simultaneous value columns. It does not
certify the Graph PH processor or transport queue. The mutation metric includes
fetches and a full history read, not just save latency.

## Candidate representation and semantic findings

- Bool, Int64, finite Double and Date use native columns.
- UInt64 uses a zero-padded 20-digit text value, preserving its complete range and
  lexical ordering without Double rounding. The discriminator separates types.
- Decimal uses exact text. The separate native Decimal probe deliberately checks
  two nearby 38-digit values; it is diagnostic rather than an accepted codec.
  Decimal ordering is **not** translated to text ordering.
- Ordinary String, UUID and URL without a base use text. Relative URLs with a
  base are explicitly rejected by the candidate: the existing envelope codec also
  loses that URL identity. This pre-existing limitation has a separate diagnostic
  and acceptance gate; it is not hidden inside a passing round-trip assertion. Native string SQL comparisons are not
  assumed to equal Swift semantics: audit probes canonical Unicode equality.
- A String containing NUL uses its existing envelope in opaque bytes after the
  first typed pilot exposed native text round-trip loss. It remains a String
  on decode. A production planner would need explicit handling for such rows.
- Data uses native binary storage. Array/Object/Encoded retain GraphValueCodec
  bytes. There is one authoritative representation, no scalar plus shadow blob.

A queryable column is not sufficient proof of query equivalence. The timed
fixtures use homogeneous numeric types and ASCII strings. A production planner
must preserve mixed-type errors, missing/null, Unicode equality/order, budgets,
reference/dependency checks, pending edits, pinned views, cancellation and stable
paging. These remain implementation work, not exceptions waived by this probe.

## Measurements

Ten shapes: equality, 1% integer range, count through owner SUBQUERY, a two-key
conjunction through independent SUBQUERY clauses, scalar sort/top20 with ID tie
break, ASCII prefix, Date range and full-range UInt64 comparison. The follow-up adds direct property count and a two-stage conjunction
that selects owners before filtering their other property. These rely on the
fixture's audited one-property-per-key invariant. Oracle creation
is outside operation timing; result comparison remains inside. The envelope path
selects only referenced keys, decodes values and evaluates/sorts in memory. Typed
paths send native predicates/sorts/count to Core Data and assert identical IDs/
counts. `envelopesDecoded` reports actual envelope accesses in that path; zero on
typed query rows means no decoding, not zero fetched rows or zero database I/O.

Report operation/open separately, closed seed apparent directory bytes including
PH, and whole-process high-water RSS including harness/oracle/frameworks. File/OS
caches are uncontrolled; new process does not mean cold disk. Three repetitions
provide screening medians, not production tail latency. Optional `--sql-debug`
on a direct probe invocation uses Core Data's diagnostic SQL output; no SQLite
files are queried or edited with native SQLite APIs. SQL output verifies native
predicate generation, not a query-plan/index-use certificate.

Apple describes SQLite predicate/sort evaluation and its constraints in
[Persistent Store Types and Behaviors](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html),
and exposes model indexes with
[NSFetchIndexDescription](https://developer.apple.com/documentation/coredata/nsfetchindexdescription).
Use the framework, not its private SQLite schema.

## Exit and follow-up

Retain pilot failures, medians, storage/write trade-offs and exact scope in the
result report. No full CI run is necessary for unchanged shipping inputs; the
laboratory remains outside default targets. Before adoption, design a concrete
schema/conversion and planner increment, exercise all real node kinds and graph
controls, benchmark through Graph, and validate backups, PH, observation, cloud
round-trip and independent device recovery. Consumer-owned binary-to-attachment
conversion remains separate. The v1 migration gate stays open.
