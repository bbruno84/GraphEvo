# GraphEvo 2 — A3 application model contracts

Status: first A3 increment, 2026-10-26. A1 (#70) and A2 (#71) were reviewed,
passed both platform checks and merged into `codex/graphevo-2` before this work.
The redundant CI bootstrap PR #69 was closed as superseded. This branch starts
from integrated commit `611bbff67c2ec4f37effdbbb5d7f238a7d29fe2c`.

This increment implements value mapping and a candidate-schema adapter. It does
**not** complete the A3 public database/CRUD exit or enable another store opener.
The [specification](graphevo-2-specification.md) and
[delivery plan](graphevo-2-delivery-plan.md) retain those gates.

## Modules and application contract

The Foundation-only `GraphEvoModel` target compiles in Swift 6 language mode.
Applications continue to import the single `GraphEvo` product, which exposes
explicit typealiases for the model contracts. The runtime stays independent of
application models. No unchecked Sendable declarations, preconcurrency import
suppression, macro, dynamic-member access or Core Data type is needed in a model.

`GraphModel: Sendable` requires:

```swift
var id: GraphNodeID { get }
static var graphType: String { get }
static var graphKind: GraphNodeKind { get }
init(graphRecord: GraphRecord) throws
func graphRecord() throws -> GraphRecord
```

`GraphRecord(model)` validates its declared kind, logical type and identity.
`record.decoded(as:)` performs the same validation around application decoding.
Calling an application's mapping method directly is ordinary application code;
use the validated wrappers at library boundaries. Stable persisted type/property
keys are explicit; renaming a Swift field does not implicitly rename storage.

```swift
struct Profile: GraphModel {
    static let graphType = "example.profile.v1"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let displayName: String

    init(id: GraphNodeID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id
        displayName = try graphRecord.value(for: "display_name")
    }

    func graphRecord() throws -> GraphRecord {
        try GraphRecord(id: id, type: Self.graphType,
                        properties: ["display_name": displayName.graphValue])
    }
}
```

A model value is detached. Editing it does not write a store. A record contains
properties, tags, groups, optional creation date and directed relationship or
action-set references. Reading a reference does not fetch its target. Optional
relationship endpoints and empty actions remain representable; target existence,
entity-kind resolution and complete graph integrity need the later storage scope.

## Identity and edits

`GraphID` wraps a UUID. `GraphNodeID` combines a graph ID and UUID. Constructors
can allocate new IDs or accept retained UUIDs. These are the candidate logical
value format, not a claim that the current native schema persists them. The
adapter requires an explicit caller-supplied mapping for a node and its entity
references. It never derives these IDs from v1 IDs, file URLs, runtime generations
or Core Data URIs. Tests retain their mappings explicitly; production persistence,
replica recovery and v1 identity translation remain D14/A3/A4 work.

Record construction rejects references to another graph. This is a value-shape
check, not proof of actual persistent membership or permission. Entity deletion
and edge cleanup must be tested when the mutation gateway is implemented.

`GraphRecordPatch` names the target ID, property set/remove changes, tag/group
additions/removals and an optional endpoint replacement. Applying a patch to a
record preserves every untouched property, including unknown encoded values,
along with its type, ID and creation date. It rejects a different target ID,
conflicting tag/group changes, empty property keys, cross-graph references and
changes of node kind. An endpoint replacement is explicit; nil means unchanged.

Patches must be applied to **current** state inside the mutation scope, not to a
stale cached record followed by wholesale replacement. No compare-and-swap or
remote conflict policy is implemented here. Encoding a typed model is suitable
for a new record; it is not an implicit replace-all update of an existing one.

## Values and codec boundary

`GraphValue` distinguishes null, Bool, signed/unsigned 64-bit integers, Double,
Decimal, String, Data, Date, URL, UUID, arrays, string-keyed objects and encoded
payloads. `GraphEncodedValue` retains a nonempty codec name, positive version and
exact Data; it does not execute a codec. No wire/archive format is frozen by
this increment. GraphValue and GraphRecord deliberately do not acquire an
implicit synthesized Codable persistence format.

`GraphPropertyValue` converts these explicitly to application property types.
Standard conversions are strict: Bool is not integer 1, and a Double field does
not silently coerce an integer. Optional fields decode `.null` to nil, while an
absent key still throws `missingProperty`. Incorrect representations throw a
keyed `propertyDecodingFailed` retaining their underlying error. Optional fields
may inspect `properties[key]` when an application's policy accepts missing data.

| Value | Detached contract | Candidate-schema adapter |
|---|---|---|
| Bool, signed/unsigned integers | Distinct cases | NSNumber bridge distinguishes CFBoolean and signedness; boundary tests include Int64.min and UInt64.max |
| Double, Decimal, String | Explicit representation | Native supported values; no query-cost promise |
| Data, Date, URL | Transferable values | Existing supported property archive |
| Arrays, objects | Nested values | Recursive conversion of supported contained values; no implicit nested-field queryability |
| Null | Explicit absence, distinct from missing | Writes rejected pending a lossless representation; legacy nil-backed property reads fail visibly |
| UUID | Explicit UUID value | Writes rejected pending a selected native encoding |
| Encoded payload | Unknown codec/version bytes retained | Writes rejected pending explicit codec/storage integration |
| Legacy image/PDF/custom wrapper values | No catch-all Any | Require explicit adapters; unknown values fail rather than disappear from a successful snapshot |

The null restriction follows a measured test: assigning NSNull through the
current facade saves but its later property read exposes a boxed nil. Treating
that as an absent dictionary key or fabricated successful null would obscure
an unresolved representation. The new adapter rejects null writes before any
edit and reports ambiguous existing values. This finding does not establish
that every legacy nullable format behaves identically or require a model change
now. Lossless null/codec migration remains mandatory work, not an accepted loss.

## Candidate-schema adapter and tests

`GraphRecordMapper` is package-only and runs inside an existing scoped Graph
operation. Snapshotting uses public Node/Entity/Relationship/Action facades and
returns a detached record. Decoder diagnostics propagate rather than becoming a
successful partial snapshot. Native values/classes never cross into models.

Its write adapter supports property/tag/group patches. It converts every changed
value before the first edit, preserving untouched native rows and failing without
partial edits even if a caller catches an unsupported-value error. Structural
endpoint writes are deliberately rejected until graph membership and identity
resolution are available. Detached endpoint patches already validate shape.
The adapter still uses the v1 facades' internal synchronous queue helpers; this
does not mean those legacy helpers have been removed from the whole library.

Tests cover protocol mapping for all three node kinds, strict missing/null/invalid
semantics, encoder/decoder identity checks, graph-aware references, detached
partial edits, exact unknown bytes and metadata retention, main-actor/non-UI
transfer, persisted SQLite patch/reopen, native numeric/container conversion,
unsupported-write atomicity, decoder-error propagation and legacy null behavior.
The standalone ModelConsumer executable imports only GraphEvo and compiles in
Swift 6; CI runs it on the macOS job in addition to package tests.

## Next A3 work

Before declaring the stage complete:

- Persist/recover candidate graph/node IDs and implement versioned v1 reference
  translation without using local object URIs as durable identities.
- Enforce legacy/v2 store ownership exclusion before exposing a v2 public opener.
- Implement typed scoped creation, fetch, patch, endpoint resolution and deletion,
  with no application context escape, and test complete structural invariants.
- Resolve null/UUID/codec storage and inventory remaining legacy values with
  lossless retention/conversion paths.
- Run an independent typed CRUD consumer and a UI integration example against
  that public gateway, then reconcile D02/D04/D11/D14.

The existing Core Data schema and production stores are unchanged.


Validation on 2026-10-26 with Xcode 27.1 / Swift 6.4: all 322 legacy, 46 runtime
and 16 model tests passed on macOS 27.0.1. The 62 runtime/model tests passed on
iPhone 17 / iOS 26.5 Simulator with no skips. Both external consumer executables,
manifest validation and diff checks passed. These local results do not certify
minimum OS versions, remote membership, a complete migration or full A3 delivery.
