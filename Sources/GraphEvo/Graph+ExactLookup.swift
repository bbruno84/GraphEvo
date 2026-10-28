import CoreData

public extension Graph {
    /// Resolves legacy physical IDs in this graph without scanning the entity type.
    /// IDs omit store identity; an equal ID from another store can resolve locally.
    func entities(type: String, matchingIDs ids: [String]) -> [Entity] {
        guard let context = managedObjectContext, !ids.isEmpty else { return [] }
        return context.performAndWait {
            var seen = Set<NSManagedObjectID>()
            return ids.compactMap { id in
                guard let entity = resolveExactEntity(id, in: context), entity.type == type,
                      seen.insert(entity.objectID).inserted else { return nil }
                return Entity(managedNode: entity)
            }
        }
    }

    /// Finds every entity with an exact string property value. Native fetches
    /// narrow by type and property name; transformable values are compared in
    /// Swift without case folding or wildcard interpretation.
    func entities(type: String, property name: String, exactly value: String) -> [Entity] {
        guard let context = managedObjectContext else { return [] }
        return context.performAndWait {
            let predicate = NSPredicate(format: "type == %@ AND ANY propertySet.name == %@", type, name)
            let candidates: [Entity] = exactLookupCandidates(in: context, predicate: predicate)
            return candidates.filter { ($0[dynamicMember: name] as? String) == value }
        }
    }

    /// Finds directed relationships of one exact type. Nil leaves an endpoint
    /// unrestricted; an empty list matches nothing. Each non-nil endpoint list
    /// becomes a native object-ID predicate, retaining parallel edges.
    func relationships(type: String, subjectIDs: [String]? = nil,
                       objectIDs: [String]? = nil) -> [Relationship] {
        guard let context = managedObjectContext,
              subjectIDs?.isEmpty != true, objectIDs?.isEmpty != true else { return [] }
        return context.performAndWait {
            var parts = [NSPredicate(format: "type == %@", type)]
            if let subjectIDs {
                let ids = Set(subjectIDs.compactMap { resolveExactEntity($0, in: context)?.objectID })
                guard !ids.isEmpty else { return [] }
                parts.append(NSPredicate(format: "subject IN %@", Array(ids)))
            }
            if let objectIDs {
                let ids = Set(objectIDs.compactMap { resolveExactEntity($0, in: context)?.objectID })
                guard !ids.isEmpty else { return [] }
                parts.append(NSPredicate(format: "object IN %@", Array(ids)))
            }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
            return exactLookupCandidates(in: context, predicate: predicate)
        }
    }
}

private extension Graph {
    /// The final URI component is p<digits> for permanent SQLite object IDs.
    /// The rightmost such component avoids ambiguity when an application type
    /// itself ends in p<digits>. The full legacy ID is validated after lookup.
    func resolveExactEntity(_ id: String, in context: NSManagedObjectContext) -> ManagedEntity? {
        guard id.hasPrefix(String(NodeClass.entity.rawValue)),
              let range = id.range(of: "p[0-9]+$", options: .regularExpression),
              let coordinator = context.persistentStoreCoordinator else { return nil }
        let suffix = String(id[range])
        for store in coordinator.persistentStores {
            guard let storeIdentifier = store.identifier,
                  let uri = URL(string: "x-coredata://\(storeIdentifier)/\(ModelIdentifier.entityName)/\(suffix)"),
                  let objectID = coordinator.managedObjectID(forURIRepresentation: uri),
                  objectID.persistentStore === store,
                  objectID.entity.name == ModelIdentifier.entityName else { continue }
            do {
                guard let entity = try context.existingObject(with: objectID) as? ManagedEntity,
                      !entity.isDeleted,
                      id == "\(NodeClass.entity.rawValue)\(entity.type)\(suffix)" else { continue }
                return entity
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain && nsError.code == NSManagedObjectReferentialIntegrityError else {
                    if isReadSnapshot { snapshotReadError = error }
                    emit(.error(.query(underlying: error)))
                    return nil
                }
            }
        }
        return nil
    }

    func exactLookupCandidates<T: Node>(in context: NSManagedObjectContext,
                                        predicate: NSPredicate) -> [T] {
        guard let identifier = NodeClass(nodeType: T.self)?.identifier else { return [] }
        let request = NSFetchRequest<ManagedNode>(entityName: identifier)
        request.fetchBatchSize = batchSize
        request.predicate = predicate
        do {
            return try context.fetch(request).map { T(managedNode: $0) }
        } catch {
            if isReadSnapshot { snapshotReadError = error }
            emit(.error(.query(underlying: error)))
            return []
        }
    }
}
