import CoreData
import Foundation

private struct GraphReference: Decodable { let rawValue: UUID }
private struct NodeReference: Decodable { let graphID: GraphReference; let rawValue: UUID }
private struct Fixture: Decodable {
    let a: GraphReference; let b: GraphReference
    let rootA: NodeReference; let childA: NodeReference; let edgeA: NodeReference; let actionA: NodeReference
    let rootB: NodeReference; let childB: NodeReference; let edgeB: NodeReference; let actionB: NodeReference
}
private struct Envelope<Value: Decodable>: Decodable { let run: UUID; let value: Value }
private enum Failure: Error { case arguments, model, resource, row }

/// No Graph import/dependency, no cloud container, no managed subclasses or application decoder.
@main struct CoreDataReader {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw Failure.arguments }
        let modelURL = URL(fileURLWithPath: arguments[1]), fixtureURL = URL(fileURLWithPath: arguments[2])
        let storeURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        guard let model = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSManagedObjectModel.self, from: Data(contentsOf: modelURL)) else { throw Failure.model }
        guard model.versionIdentifiers.count == 1, model.versionIdentifiers.contains("GraphEvo.CS01.local.1") || model.versionIdentifiers.contains("GraphEvo.CS01.local.2") else { throw Failure.model }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL)
        guard metadata[NSStoreModelVersionIdentifiersKey] as? [String] == model.versionIdentifiers.map({ $0 as? String }).compactMap({ $0 }),
              model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
              model.entities.allSatisfy({ $0.managedObjectClassName == NSStringFromClass(NSManagedObject.self) }) else { throw Failure.model }
        let f = try JSONDecoder().decode(Envelope<Fixture>.self, from: Data(contentsOf: fixtureURL)).value
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL,
            options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true,
                      NSMigratePersistentStoresAutomaticallyOption: false, NSInferMappingModelAutomaticallyOption: false])
        guard coordinator.persistentStores.count == 1,
              store.url?.standardizedFileURL.resolvingSymlinksInPath() == storeURL else { throw Failure.resource }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let result: [String: Any]
        do {
            result = try context.performAndWait {
                guard let boundCoordinator = context.persistentStoreCoordinator,
                      boundCoordinator.persistentStores.count == 1,
                      let boundStore = boundCoordinator.persistentStores.first,
                      boundStore.url?.standardizedFileURL.resolvingSymlinksInPath() == storeURL else { throw Failure.resource }
                var result: [String: Any] = ["oneOpenedStore": true, "boundToExactFile": true, "modelCompatible": true]
                for a in [true, false] {
                    let graph = a ? f.a.rawValue : f.b.rawValue
                    let expected: [String: [String: String]] = [
                        "ManagedEntity": [(a ? f.rootA : f.rootB).rawValue.uuidString: "CS01.root", (a ? f.childA : f.childB).rawValue.uuidString: "CS01.child"],
                        "ManagedRelationship": [(a ? f.edgeA : f.edgeB).rawValue.uuidString: "CS01.edge"],
                        "ManagedAction": [(a ? f.actionA : f.actionB).rawValue.uuidString: "CS01.action"]]
                    var count = 0, matches = true
                    for name in ["ManagedEntity", "ManagedRelationship", "ManagedAction"] {
                        let predicate = NSPredicate(format: "ge2GraphID == %@ AND type BEGINSWITH %@", graph.uuidString, "CS01.")
                        let request = NSFetchRequest<NSDictionary>(entityName: name)
                        request.resultType = .dictionaryResultType; request.propertiesToFetch = ["ge2GraphID", "ge2NodeID", "type"]
                        request.predicate = predicate; request.affectedStores = [boundStore]; request.includesPendingChanges = false
                        let rows = try context.fetch(request)
                        let ids = NSFetchRequest<NSManagedObjectID>(entityName: name)
                        ids.resultType = .managedObjectIDResultType; ids.predicate = predicate
                        ids.affectedStores = [boundStore]; ids.includesPendingChanges = false
                        let objectIDs = try context.fetch(ids)
                        guard objectIDs.count == rows.count, objectIDs.allSatisfy({ !$0.isTemporaryID && $0.persistentStore === boundStore }) else { throw Failure.resource }
                        var actual: [String: String] = [:]
                        for row in rows {
                            guard row["ge2GraphID"] as? String == graph.uuidString,
                                  let id = row["ge2NodeID"] as? String, let type = row["type"] as? String,
                                  actual.updateValue(type, forKey: id) == nil else { throw Failure.row }
                        }
                        matches = matches && actual == expected[name]!
                        count += rows.count
                    }
                    result[a ? "nativeRowsA" : "nativeRowsB"] = count
                    result[a ? "exactNativeIdentitiesA" : "exactNativeIdentitiesB"] = matches && count == 4
                }
                return result
            }
        } catch {
            context.performAndWait { context.reset() }; try coordinator.remove(store); throw error
        }
        context.performAndWait { context.reset() }; try coordinator.remove(store)
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
