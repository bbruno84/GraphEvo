import CoreData
import Foundation

/// Temporary resource-wide refusal until normal stores own a format registry.
/// Fetch native node metadata only, before any application property-row fetch.
enum GraphDataFormatAdmission {
    static func requireUndeclared(in context: NSManagedObjectContext) throws {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else {
            throw GraphStoreError.unsupportedLayout
        }
        // Only the isolated package-only M2a owner interprets declared formats today.
        if model.versionIdentifiers == [AnyHashable(GraphDataMigrationLaboratory.modelIdentifier)] { return }
        _ = try GraphNativeIdentityColumns.validateModel(in: context)
        for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
            guard model.entitiesByName[name]?.attributesByName[GraphNativeIdentityColumns.dataVersionAttribute] != nil else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "%K != nil", GraphNativeIdentityColumns.dataVersionAttribute)
            request.fetchLimit = 1
            request.includesPendingChanges = true
            request.includesPropertyValues = false
            request.affectedStores = context.persistentStoreCoordinator?.persistentStores
            guard try context.fetch(request).isEmpty else { throw GraphStoreError.dataFormatAdmissionRequired }
        }
    }

    static func requireInsert(_ record: GraphRecord, in context: NSManagedObjectContext) throws {
        if record.dataVersion != nil,
           context.persistentStoreCoordinator?.managedObjectModel.versionIdentifiers != [AnyHashable(GraphDataMigrationLaboratory.modelIdentifier)] {
            throw GraphStoreError.dataFormatAdmissionRequired
        }
    }

    static func version(of node: Node) -> Int64? {
        guard node.node.entity.attributesByName[GraphNativeIdentityColumns.dataVersionAttribute] != nil else { return nil }
        return (node.node.value(forKey: GraphNativeIdentityColumns.dataVersionAttribute) as? NSNumber)?.int64Value
    }
}
