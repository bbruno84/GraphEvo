# Application models mapped in extensions

Status: focused alpha correction on `codex/v2-extension-model-mapping`, directly
from integrated MF08/#130. Source API changes are intentional; native S03, values,
cloud/session/backup formats and persistent identities are unchanged.

## Domain identity and graph reference

A domain model can import only Foundation, carry its own UUID and declare
Sendable in its original file:

```swift
import Foundation

struct Person: Sendable {
    let id: UUID
    var name: String
}
```

All GraphEvo conformance may live in a different file:

```swift
import GraphEvo

extension Person: GraphModel {
    static var graphType: String { "Person" }
    static var graphKind: GraphNodeKind { .entity }

    init(graphRecord: GraphRecord) throws {
        self.init(id: graphRecord.id.rawValue,
                  name: try graphRecord.value(for: "name"))
    }

    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType,
                        properties: ["name": .string(name)])
    }
}
```

`GraphModel` now refines Identifiable and Sendable with a Sendable ID. The default
UUID mapping combines the **existing** application UUID with the scope's GraphID.
No UUID is generated on serialization/read, no identity lookup table is created,
and no graph-specific stored member is required in the domain type. The library
checks declared type/kind and complete bound identity after encoding/decoding.
Mapping methods must be deterministic and preserve identity. Other application
ID representations need an explicit stable `graphNodeID(in:)` mapping; the library
does not hash arbitrary IDs into UUIDs.

A UUID alone is not a cross-graph reference. The same UUID in A and B identifies
two independent graph nodes. Typed insert uses the receiving scope's GraphID;
UUID fetch/delete overloads resolve only in that graph. Returned GraphNodeIDs,
record/patch IDs and relationship/action endpoints retain their full graph-aware
identity and existing cross-graph validation. Nothing searches other graphs or
silently moves a persisted record.

## Serialization and compatibility

`GraphRecord(model, in: graphID)` is the validated detached serialization entry.
The serializer requirement is now `graphRecord(in:)`, so an unscoped UUID model
cannot invent its graph at encoding time. Store/scope typed insert and the
retained explicit native shared-insertion facade supply their current GraphID.
There is no implicit current graph, task-local ambient scope or global registry.

Existing graph-scoped models may keep `id: GraphNodeID`. Their default identity
mapping retains the original graph; opening/inserting into another graph remains
refused. For these types only, `GraphRecord(model)` and `graphRecord()` remain
conveniences that delegate to `graphRecord(in: model.id.graphID)`. Conformers must
update their serializer signature. This is a small alpha source-compatibility
convenience, not a second persistence implementation or a promise of v1 API
compatibility. Internal attachment envelopes retain their original graph-aware
metadata and validate the supplied scope without changing stored bytes.

Separate-file conformance does not permit adding stored properties. The base
model still needs its application identity. Sendable conformance belongs in the
original type's file when required by Swift's checked-conformance rules; an
extension in another file does not make a mutable/non-Sendable domain safe.

## Evidence and boundaries

The independent ModelConsumer now has `Profile.swift` importing only Foundation,
and `Profile+GraphModel.swift` importing GraphEvo. It exercises CRUD, native reopen,
query/Combine, attachment ownership and multiple graphs with the UUID model.
New regression tests use the same two-file separation and cover persistent UUIDs,
same-UUID/different-graph isolation, typed query/observation/patch/delete, mismatch
refusal in both mapping directions, rollback and detached transfer. Existing
GraphNodeID-backed tests retain their graph-bound checks.

No Core Data model/property encoding or cloud synchronization algorithm changes.
The retained TP01 native-property experiment remains separate: scalar-column
adoption is future schema/planner work. Historical non-default probes keep their
source pins; compiled laboratory/consumer targets update their mapping signature.
Physical CloudKit/schema adoption is not claimed by this API correction.

## Local review checkpoint

Final shipping code passes 892 macOS functions (331 legacy XCTest, 462 store,
76 runtime, 23 model), 560 selected iOS 18.5 functions/666 invocations, and the
independent ModelConsumer/ProcessConsumer. Manifest and diff checks pass.
Early compile checks identified the remaining generic native shared insertion
call and missing test-only import/throw annotations; these were corrected before
the successful full checks. No production behavior was changed to bypass a test.
Review checks identity scope, malformed serializer/decoder refusal, generic
shared insertion, attachment compatibility and the two-file consumer. No remaining
blocker was found. This is agent review, not independent human approval.
A single final full CI checkpoint follows review; no physical cloud/schema
acceptance claim is added by this mapping-only increment.
