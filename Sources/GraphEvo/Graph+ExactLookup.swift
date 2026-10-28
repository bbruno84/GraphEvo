import CoreData

public extension Graph {
    /// Finds entities of one exact type whose legacy physical IDs are in `ids`.
    /// IDs are scoped to this graph. Legacy IDs do not encode store identity, so
    /// an equal ID from another store cannot be distinguished from a local ID.
    func entities(type: String, matchingIDs ids: [String]) -> [Entity] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        return exactLookupCandidates(type: type)
            .filter { wanted.contains($0.id) }
    }

    /// Finds every entity with an exact string property value. The type and
    /// property name narrow the native fetch; the transformable value is
    /// compared in memory with case, diacritics, and wildcard characters intact.
    func entities(type: String, property name: String, exactly value: String) -> [Entity] {
        return exactLookupCandidates(type: type, propertyName: name)
            .filter { ($0[dynamicMember: name] as? String) == value }
    }

    /// Finds directed relationships of one exact type. A nil endpoint list
    /// leaves that direction unrestricted; an empty list matches nothing.
    /// Endpoint IDs are compared in the graph's owning context.
    func relationships(type: String, subjectIDs: [String]? = nil,
                       objectIDs: [String]? = nil) -> [Relationship] {
        let subjects = subjectIDs.map(Set.init)
        let objects = objectIDs.map(Set.init)
        guard subjects?.isEmpty != true, objects?.isEmpty != true else { return [] }
        return exactLookupCandidates(type: type)
            .filter { relationship in
                (subjects == nil || relationship.subject.map { subjects!.contains($0.id) } == true)
                    && (objects == nil || relationship.object.map { objects!.contains($0.id) } == true)
            }
    }
}

private extension Graph {
    func exactLookupCandidates<T: Node>(type: String, propertyName: String? = nil) -> [T] {
        guard let context = managedObjectContext,
              let identifier = NodeClass(nodeType: T.self)?.identifier else { return [] }
        var matches: [T] = []
        context.performAndWait {
            let request = NSFetchRequest<ManagedNode>(entityName: identifier)
            request.fetchBatchSize = batchSize
            if let propertyName {
                request.predicate = NSPredicate(format: "type == %@ AND ANY propertySet.name == %@", type, propertyName)
            } else {
                request.predicate = NSPredicate(format: "type == %@", type)
            }
            do {
                matches = try context.fetch(request).map { T(managedNode: $0) }
            } catch {
                if isReadSnapshot { snapshotReadError = error }
                emit(.error(.query(underlying: error)))
            }
        }
        return matches
    }
}
