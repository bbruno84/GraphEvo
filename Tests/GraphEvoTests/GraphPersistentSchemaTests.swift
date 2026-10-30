import CoreData
import GraphEvoRuntime
import XCTest
@testable import GraphEvo

@MainActor final class GraphPersistentSchemaTests: XCTestCase {
    private let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]

    func testS01IsExactlyTheSelectedAdditiveShapeWithStableIdentity() throws {
        let base = Model.makeModel(), model = GraphRuntimeSchema.makeNativeModel()
        XCTAssertEqual(model.versionIdentifiers, ["GraphEvo.v2.schema.1"])
        XCTAssertEqual(model.entities.count, 12)
        XCTAssertEqual(Set(model.entitiesByName.keys), Set(base.entitiesByName.keys))
        XCTAssertEqual(model.entityVersionHashesByName, GraphRuntimeSchema.nativeIdentity.entityVersionHashes)
        XCTAssertEqual(GraphRuntimeSchema.nativeIdentity.requiredModelVersionIdentifier, "GraphEvo.v2.schema.1")
        let second = GraphRuntimeSchema.makeNativeModel()
        XCTAssertFalse(model === second)
        XCTAssertEqual(model.entityVersionHashesByName, second.entityVersionHashesByName)
        for entity in model.entities {
            let name = try XCTUnwrap(entity.name), original = try XCTUnwrap(base.entitiesByName[name])
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            XCTAssertEqual(Set(entity.relationshipsByName.keys), Set(original.relationshipsByName.keys))
            if kinds.contains(name) {
                XCTAssertEqual(Set(entity.attributesByName.keys), Set(original.attributesByName.keys).union(["ge2GraphID", "ge2NodeID", "ge2DataVersion"]))
                for key in ["ge2GraphID", "ge2NodeID", "ge2DataVersion"] {
                    let attribute = try XCTUnwrap(entity.attributesByName[key])
                    XCTAssertEqual(attribute.attributeType, key == "ge2DataVersion" ? .integer64AttributeType : .stringAttributeType)
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
    func testS01MatchesVersionedMigrationEvidenceButNotHistoricalIdentityOnlyModels() {
        XCTAssertEqual(GraphRuntimeSchema.nativeIdentity.entityVersionHashes,
                       GraphSchemaMigrationLaboratory.model(.versioned).entityVersionHashesByName)
        XCTAssertNotEqual(GraphRuntimeSchema.nativeIdentity.entityVersionHashes,
                          GraphSchemaMigrationLaboratory.model(.native).entityVersionHashesByName)
        XCTAssertNil(GraphNativeIdentityPrototype.makeModel(indexed: true)
            .entitiesByName[ModelIdentifier.entityName]?.attributesByName["ge2DataVersion"])
    }

    private func validate(_ model: NSManagedObjectModel) throws -> Bool {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait { try GraphNativeIdentityColumns.validateModel(in: context) }
    }

    func testModelPreflightRejectsPartialMalformedOrUnindexedVersionedShapes() throws {
        XCTAssertTrue(try validate(GraphRuntimeSchema.makeNativeModel()))
        XCTAssertTrue(try validate(GraphNativeIdentityPrototype.makeModel(indexed: false)))
        XCTAssertFalse(try validate(Model.makeModel()))
        for variant in 0..<7 {
            let model = GraphRuntimeSchema.makeNativeModel()
            let entity = try XCTUnwrap(model.entitiesByName[ModelIdentifier.actionName])
            let version = try XCTUnwrap(entity.attributesByName["ge2DataVersion"])
            switch variant {
            case 0: entity.properties.removeAll { $0.name == "ge2DataVersion" }
            case 1: version.attributeType = .stringAttributeType
            case 2: version.isOptional = false
            case 3: version.defaultValue = NSNumber(value: 1)
            case 4: entity.properties.removeAll { $0.name == "ge2GraphID" || $0.name == "ge2NodeID" }
            case 5: version.isTransient = true
            default: entity.indexes = []
            }
            XCTAssertThrowsError(try validate(model)) { error in
                guard case GraphStoreError.unsupportedLayout = error else {
                    return XCTFail("Unexpected schema preflight error: \(error)")
                }
            }
        }
    }
}
