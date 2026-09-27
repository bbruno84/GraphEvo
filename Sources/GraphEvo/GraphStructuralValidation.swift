import CoreData
import Foundation

/// The observable state of a reference in the persisted local graph.
public enum GraphStructuralReferenceState: String {
    case absent
    case unresolved
    case materialized
}

/// One root or relationship reference inspected by structural validation.
/// Object IDs identify local objects; no managed objects escape the validation context.
public struct GraphStructuralReference {
    /// Nil for the root object.
    public let sourceObjectID: NSManagedObjectID?
    /// Nil for the root; otherwise the Core Data relationship name.
    public let relationshipName: String?
    /// Nil for an empty optional relationship or collection.
    public let destinationObjectID: NSManagedObjectID?
    public let state: GraphStructuralReferenceState
    public let error: Error?
}

/// A bounded check of the dependencies currently exposed by Core Data.
/// This does not certify import completion or application-level validity.
public struct GraphStructuralValidationResult {
    public let objectID: NSManagedObjectID
    /// Root first, followed by references in deterministic relationship/URI order.
    public let references: [GraphStructuralReference]
    public var issues: [GraphStructuralReference] { references.filter { $0.state == .unresolved } }
    public var isValid: Bool { issues.isEmpty }
}

public enum GraphStructuralValidationError: LocalizedError {
    case missingContext
    case missingStore
    case notPersisted
    case objectNotFound
    case unexpectedEntity

    public var errorDescription: String? {
        switch self {
        case .missingContext: return "The object has no managed object context."
        case .missingStore: return "The object has no available persistent store."
        case .notPersisted: return "The object has not been persisted."
        case .objectNotFound: return "The referenced object could not be fetched from the local persistent store."
        case .unexpectedEntity: return "The referenced object has an unexpected Core Data entity."
        }
    }
}

public extension Node {
    /// Validates the saved version of this Entity, Relationship, or Action.
    /// Unsaved edits are ignored. A never-saved object fails validation.
    /// Endpoints are materialized without traversing their relationships.
    /// This synchronous operation performs store I/O; call it on the owning context's queue.
    func validateStructure() -> GraphStructuralValidationResult {
        guard let context = node.managedObjectContext else {
            return GraphStructuralValidator.failure(node.objectID, error: GraphStructuralValidationError.missingContext)
        }
        return context.performAndWait {
            GraphStructuralValidator.validate([node.objectID], from: context)[0]
        }
    }
}

/// Shared implementation for direct Node calls and report delivery. No retry or delivery policy.
internal enum GraphStructuralValidator {
    static func failure(_ id: NSManagedObjectID, error: Error) -> GraphStructuralValidationResult {
        GraphStructuralValidationResult(objectID: id, references: [GraphStructuralReference(
            sourceObjectID: nil, relationshipName: nil, destinationObjectID: id,
            state: .unresolved, error: error
        )])
    }

    /// The caller owns the source context's queue. Only IDs and the coordinator cross queues.
    static func validate(_ ids: [NSManagedObjectID], from source: NSManagedObjectContext) -> [GraphStructuralValidationResult] {
        guard !ids.isEmpty else { return [] }
        var ancestor: NSManagedObjectContext? = source
        while let parent = ancestor?.parent { ancestor = parent }
        guard let coordinator = ancestor?.persistentStoreCoordinator else {
            return ids.map { failure($0, error: GraphStructuralValidationError.missingStore) }
        }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        return context.performAndWait {
            do {
                // SQLite supports query generations; in-memory stores do not.
                if coordinator.persistentStores.allSatisfy({ $0.type == NSSQLiteStoreType }) {
                    try context.setQueryGenerationFrom(.current)
                }
                let reader = Reader(context: context)
                return ids.map { reader.validate($0) }
            } catch {
                return ids.map { failure($0, error: error) }
            }
        }
    }

    private final class Reader {
        let context: NSManagedObjectContext
        var objects: [NSManagedObjectID: Result<NSManagedObject, Error>] = [:]
        var references: [GraphStructuralReference] = []
        var expandedEdges = Set<NSManagedObjectID>()

        init(context: NSManagedObjectContext) { self.context = context }

        func validate(_ id: NSManagedObjectID) -> GraphStructuralValidationResult {
            references = []
            expandedEdges = []
            if let root = resolve(id, source: nil, relationship: nil) {
                switch root.entity.name {
                case ModelIdentifier.entityName:
                    details(root)
                    for key in ["actionObjectSet", "actionSubjectSet", "relationshipObjectSet", "relationshipSubjectSet"] {
                        for edge in destinations(root, key) { validateEdge(edge) }
                    }
                case ModelIdentifier.relationshipName, ModelIdentifier.actionName:
                    validateEdge(root)
                default:
                    references[0] = GraphStructuralReference(sourceObjectID: nil, relationshipName: nil,
                        destinationObjectID: id, state: .unresolved, error: GraphStructuralValidationError.unexpectedEntity)
                }
            }
            return GraphStructuralValidationResult(objectID: id, references: references)
        }

        func validateEdge(_ object: NSManagedObject) {
            guard expandedEdges.insert(object.objectID).inserted else { return }
            details(object)
            let keys = object.entity.name == ModelIdentifier.relationshipName
                ? ["object", "subject"] : ["objectSet", "subjectSet"]
            for key in keys {
                // Deliberately stop at endpoint attributes; never traverse the entity's edges or details.
                _ = destinations(object, key)
            }
        }

        func details(_ object: NSManagedObject) {
            for key in ["groupSet", "propertySet", "tagSet"] { _ = destinations(object, key) }
        }

        func destinations(_ object: NSManagedObject, _ key: String) -> [NSManagedObject] {
            let ids = object.objectIDs(forRelationshipNamed: key).sorted {
                $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
            }
            if ids.isEmpty {
                references.append(GraphStructuralReference(sourceObjectID: object.objectID,
                    relationshipName: key, destinationObjectID: nil, state: .absent, error: nil))
            }
            return ids.compactMap { resolve($0, source: object.objectID, relationship: key) }
        }

        func resolve(_ id: NSManagedObjectID, source: NSManagedObjectID?, relationship: String?) -> NSManagedObject? {
            let result: Result<NSManagedObject, Error>
            if let cached = objects[id] {
                result = cached
            } else {
                result = Result {
                    guard !id.isTemporaryID else { throw GraphStructuralValidationError.notPersisted }
                    guard let store = id.persistentStore,
                          context.persistentStoreCoordinator?.persistentStores.contains(store) == true else {
                        throw GraphStructuralValidationError.missingStore
                    }
                    // Fetch explicitly: a registered fault alone is not proof of a persisted row.
                    let request = NSFetchRequest<NSManagedObject>()
                    request.entity = id.entity
                    request.predicate = NSPredicate(format: "SELF == %@", id)
                    request.affectedStores = [store]
                    request.includesPendingChanges = false
                    request.returnsObjectsAsFaults = false
                    request.fetchLimit = 1
                    guard let object = try context.fetch(request).first else {
                        throw GraphStructuralValidationError.objectNotFound
                    }
                    // Read attributes, including transformables, without following relationships.
                    for key in object.entity.attributesByName.keys.sorted() { _ = object.value(forKey: key) }
                    return object
                }
                objects[id] = result
            }
            switch result {
            case .success(let object):
                references.append(GraphStructuralReference(sourceObjectID: source, relationshipName: relationship,
                    destinationObjectID: id, state: .materialized, error: nil))
                return object
            case .failure(let error):
                references.append(GraphStructuralReference(sourceObjectID: source, relationshipName: relationship,
                    destinationObjectID: id, state: .unresolved, error: error))
                return nil
            }
        }
    }
}

/// Diagnostic attached to an existing Watch materialization warning/error.
public struct GraphStructuralValidationFailure: LocalizedError {
    public let result: GraphStructuralValidationResult
    public var errorDescription: String? {
        "GraphEvo structural validation failed for \(result.issues.count) persisted references."
    }
}

internal extension GraphWatchEvent {
    var isNodeDeletion: Bool {
        switch self {
        case .deletedEntity, .deletedRelationship, .deletedAction: return true
        default: return false
        }
    }
}

internal enum GraphWatchStructuralValidation {
    /// Deleted owners have no current persisted structure to validate.
    static func validate(_ envelopes: [GraphWatchEventEnvelope], in context: NSManagedObjectContext,
                         deletedIDs: Set<NSManagedObjectID> = []) -> [GraphStructuralValidationResult] {
        let deleted = deletedIDs.union(envelopes.filter { $0.event.isNodeDeletion }.map { $0.owner.objectID })
        let ids = Set(envelopes.map { $0.owner.objectID }).subtracting(deleted).sorted {
            $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
        }
        return GraphStructuralValidator.validate(ids, from: context)
    }

    static func issues(_ results: [GraphStructuralValidationResult],
                       envelopes: [GraphWatchEventEnvelope]) -> [GraphWatchMaterializationIssue] {
        results.filter { !$0.isValid }.map { result in
            let owner = envelopes.first { $0.owner.objectID == result.objectID }?.owner
            return GraphWatchMaterializationIssue(eventKind: "structuralValidation",
                objectReference: owner.map(redactedReference), error: GraphStructuralValidationFailure(result: result))
        }
    }
}
