import CoreData
import GraphEvoRuntime

/// A read-only native lookup confined to one adapter Session/context queue.
/// It batches only reserved property rows; application values and relationships are not prefetched.
/// Values remain lazy so decoding errors in another graph cannot contaminate the selected graph.
package final class GraphRuntimeMetadata {
    private let indexed: Set<NSManagedObjectID>
    private var rows: [NSManagedObjectID: [String: [NSManagedObject]]] = [:]

    package init(nodes: [Node], keys: Set<String>, context: NSManagedObjectContext) throws {
        indexed = Set(nodes.map(\.runtimeObjectID))
        let checkCancellation = StoreNativeContext.cancellationCheck(in: context)
        for (kind, name) in [(Entity.self, ModelIdentifier.entityPropertyName),
                             (Relationship.self, ModelIdentifier.relationshipPropertyName),
                             (Action.self, ModelIdentifier.actionPropertyName)] {
            let owners = nodes.filter { $0.isKind(of: kind) }.map(\.node)
            for offset in stride(from: 0, to: owners.count, by: 128) {
                try checkCancellation()
                let request = NSFetchRequest<NSManagedObject>(entityName: name)
                request.predicate = NSPredicate(format: "name IN %@ AND node IN %@", Array(keys), Array(owners[offset..<min(offset + 128, owners.count)]))
                request.includesPendingChanges = true
                request.returnsObjectsAsFaults = false
                for property in try context.fetch(request) {
                    guard let owner = property.value(forKey: "node") as? NSManagedObject,
                          let key = property.value(forKey: "name") as? String else { throw GraphStoreError.corruptIdentity }
                    rows[owner.objectID, default: [:]][key, default: []].append(property)
                }
            }
        }
    }

    package func value(for node: Node, key: String) -> Any? {
        // Newly staged facades can be introduced after the index was built. Use the original path there.
        guard indexed.contains(node.runtimeObjectID) else { return node[dynamicMember: key] }
        let matches = rows[node.runtimeObjectID]?[key]?.filter { !$0.isDeleted } ?? []
        // Preserve the facade's selection behavior for malformed duplicate names; do not eagerly decode all rows.
        if matches.count > 1 { return node[dynamicMember: key] }
        return matches.first?.value(forKey: "object")
    }
}
