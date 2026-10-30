import CoreData
import GraphEvoRuntime
import XCTest
@testable import GraphEvo

@MainActor final class GraphPersistentSchemaTests: XCTestCase {
    private let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]

    func testS02IsExactlyTheSelectedAdditiveShapeWithStableIdentity() throws {
        let base = Model.makeModel(), model = GraphRuntimeSchema.makeNativeModel()
        XCTAssertEqual(model.versionIdentifiers, ["GraphEvo.v2.schema.2"])
        XCTAssertEqual(model.entities.count, 12)
        XCTAssertEqual(Set(model.entitiesByName.keys), Set(base.entitiesByName.keys))
        XCTAssertEqual(model.entityVersionHashesByName, GraphRuntimeSchema.nativeIdentity.entityVersionHashes)
        XCTAssertEqual(GraphRuntimeSchema.nativeIdentity.requiredModelVersionIdentifier, "GraphEvo.v2.schema.2")
        let second = GraphRuntimeSchema.makeNativeModel()
        XCTAssertFalse(model === second)
        XCTAssertEqual(model.entityVersionHashesByName, second.entityVersionHashesByName)
        for entity in model.entities {
            let name = try XCTUnwrap(entity.name), original = try XCTUnwrap(base.entitiesByName[name])
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            XCTAssertEqual(Set(entity.relationshipsByName.keys), Set(original.relationshipsByName.keys))
            if kinds.contains(name) {
                XCTAssertEqual(Set(entity.attributesByName.keys), Set(original.attributesByName.keys).union(["ge2GraphID", "ge2NodeID"]))
                for key in ["ge2GraphID", "ge2NodeID"] {
                    let attribute = try XCTUnwrap(entity.attributesByName[key])
                    XCTAssertEqual(attribute.attributeType, .stringAttributeType)
                    XCTAssertTrue(attribute.isOptional); XCTAssertNil(attribute.defaultValue)
                    XCTAssertFalse(attribute.isTransient)
                }
                XCTAssertTrue(try XCTUnwrap(entity.attributesByName["createdDate"]).isOptional)
                let index = try XCTUnwrap(entity.indexes.first)
                XCTAssertEqual(entity.indexes.count, 1)
                XCTAssertEqual(index.name, name + "_ge2_identity")
                XCTAssertEqual(index.elements.compactMap(\.propertyName), ["ge2GraphID", "ge2NodeID"])
                XCTAssertTrue(index.elements.allSatisfy { $0.collationType == .binary })
            } else {
                // Detail fields, including legacy appDataVersion/external storage, are unchanged.
                XCTAssertEqual(entity.versionHash, original.versionHash)
            }
        }
    }

    @available(iOS 17, macOS 14, *)
    func testS02RetainsIdentityShapeButRejectsHistoricalVersionedShape() {
        XCTAssertEqual(GraphRuntimeSchema.nativeIdentity.entityVersionHashes,
                       GraphSchemaMigrationLaboratory.model(.native).entityVersionHashesByName)
        XCTAssertNotEqual(GraphRuntimeSchema.nativeIdentity.entityVersionHashes,
                          GraphSchemaMigrationLaboratory.model(.versioned).entityVersionHashesByName)
        for name in kinds {
            XCTAssertNil(GraphRuntimeSchema.makeNativeModel().entitiesByName[name]?.attributesByName["ge2DataVersion"])
        }
    }

    private func validate(_ model: NSManagedObjectModel) throws -> Bool {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait { try GraphNativeIdentityColumns.validateModel(in: context) }
    }

    func testModelPreflightRejectsPartialOrMalformedIdentityShapes() throws {
        XCTAssertTrue(try validate(GraphRuntimeSchema.makeNativeModel()))
        XCTAssertTrue(try validate(GraphNativeIdentityPrototype.makeModel(indexed: false)))
        XCTAssertFalse(try validate(Model.makeModel()))
        for variant in 0..<6 {
            let model = GraphRuntimeSchema.makeNativeModel()
            let entity = try XCTUnwrap(model.entitiesByName[ModelIdentifier.actionName])
            let identity = try XCTUnwrap(entity.attributesByName["ge2NodeID"])
            switch variant {
            case 0: entity.properties.removeAll { $0.name == "ge2NodeID" }
            case 1: identity.attributeType = .integer64AttributeType
            case 2: identity.isOptional = false
            case 3: identity.defaultValue = "invalid"
            case 4: entity.properties.removeAll { $0.name == "ge2GraphID" || $0.name == "ge2NodeID" }
            default: identity.isTransient = true
            }
            XCTAssertThrowsError(try validate(model)) { error in
                guard case GraphStoreError.unsupportedLayout = error else {
                    return XCTFail("Unexpected schema preflight error: \(error)")
                }
            }
        }
    }
}
