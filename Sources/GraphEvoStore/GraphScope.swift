import CoreData
import Foundation
import GraphEvoModel

/// Synchronous context-confined scope. Not Sendable and invalid after its body returns.
public class GraphReadScope {
    public let graphID: GraphID
    private var context: NSManagedObjectContext?
    private let adapter: GraphStoreAdapter

    package init(context: NSManagedObjectContext, graphID: GraphID, adapter: GraphStoreAdapter) {
        self.context = context; self.graphID = graphID; self.adapter = adapter
    }

    package let queryScopeID = UUID()
    package var queryView: GraphQueryLocalView { GraphQueryLocalView(graphID: graphID, scopeID: queryScopeID, includesPendingChanges: self is GraphMutation) }

    package func invalidate() { context = nil }

    package func withContext<Value>(_ body: (NSManagedObjectContext, GraphStoreAdapter) throws -> Value) throws -> Value {
        guard let context else { throw GraphStoreError.expiredScope }
        return try body(context, adapter)
    }

    public func record(for id: GraphNodeID) throws -> GraphRecord? {
        guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
        return try withContext { try $1.fetch($0, graphID, id) }
    }

    public func fetch<Model: GraphModel>(_ id: GraphNodeID, as type: Model.Type = Model.self) throws -> Model? {
        try record(for: id)?.decoded(as: type)
    }

    public func fetchAll<Model: GraphModel>(_ type: Model.Type) throws -> [Model] {
        try withContext { context, adapter in
            try adapter.fetchAll(context, graphID, Model.graphType, Model.graphKind).map { try $0.decoded(as: type) }
        }
    }
}

/// Explicit edits run on the native transaction queue and commit only when the body succeeds.
public final class GraphMutation: GraphReadScope {
    @discardableResult public func insert<Model: GraphModel>(_ model: Model) throws -> GraphNodeID {
        try insert(GraphRecord(model))
    }

    @discardableResult public func insert(_ record: GraphRecord) throws -> GraphNodeID {
        guard record.id.graphID == graphID else { throw GraphStoreError.foreignGraph }
        try withContext { try $1.insert($0, graphID, record) }
        return record.id
    }

    public func patch(_ patch: GraphRecordPatch) throws -> GraphRecord {
        guard patch.id.graphID == graphID else { throw GraphStoreError.foreignGraph }
        return try withContext { try $1.patch($0, graphID, patch) }
    }

    public func patch<Model: GraphModel>(_ patch: GraphRecordPatch, as type: Model.Type) throws -> Model {
        guard let current = try record(for: patch.id) else { throw GraphStoreError.missingNode }
        let model = try patch.applying(to: current).decoded(as: type)
        _ = try self.patch(patch)
        return model
    }

    public func delete(_ id: GraphNodeID) throws {
        guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
        try withContext { try $1.delete($0, graphID, id) }
    }
}
