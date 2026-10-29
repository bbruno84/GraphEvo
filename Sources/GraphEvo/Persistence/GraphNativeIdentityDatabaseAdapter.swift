import CoreData
import Foundation
import GraphEvoModel
import GraphEvoStore

/// Fresh native alpha protocol with explicit local/mirrored admission. Historical prototype markers are deliberately not accepted.
enum GraphNativeIdentityDatabaseAdapter {
    private static func access(allowsMirroring: Bool = false) -> GraphNativeIdentityAccess {
        GraphNativeIdentityAccess(activationKey: GraphTypedStoreAdapter.prefix + "nativeIdentityLayout",
                                  activationVersion: "alpha.1", allowsMirroring: allowsMirroring)
    }

    static var database: GraphDatabaseAdapter { makeDatabase() }

    static func makeDatabase(allowsMirroring: Bool = false) -> GraphDatabaseAdapter {
        let access = access(allowsMirroring: allowsMirroring)
        let base = GraphTypedStoreAdapter.database
        let graph = GraphStoreAdapter(initialize: { _, _ in throw GraphStoreError.unsupportedLayout },
            fetch: { context, graphID, id in
                guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
                return try access.record(context, id: id)
            }, fetchAll: { context, graphID, type, kind in
                try access.checkGraph(context, graphID: graphID)
                return try base.graph.fetchAll(context, graphID, type, kind)
            }, insert: { context, graphID, record in
                try access.checkGraph(context, graphID: graphID)
                try base.graph.insert(context, graphID, record)
            }, patch: { context, graphID, patch in
                try access.checkGraph(context, graphID: graphID)
                return try base.graph.patch(context, graphID, patch)
            }, delete: { context, graphID, id in
                try access.checkGraph(context, graphID: graphID)
                try base.graph.delete(context, graphID, id)
            }, attachmentMetadata: { context, graphID in
                _ = try access.validateIdentityInventory(context, graphID: graphID)
                guard let list = base.graph.attachmentMetadata else { throw GraphStoreError.unsupportedLayout }
                return try list(context, graphID)
            }, query: { context, graphID, request in
                try access.checkGraph(context, graphID: graphID)
                guard let query = base.graph.query else { throw GraphStoreError.unsupportedLayout }
                return try query(context, graphID, request)
            })
        return GraphDatabaseAdapter(graph: graph, catalog: { try access.catalog($0) }, create: { context, id in
            try base.create(context, id)
            try access.activateFreshGraph(context, graphID: id)
        }, upgrade: { _, _ in throw GraphStoreError.unsupportedLayout })
    }

    static func validate(_ context: NSManagedObjectContext, graphID: GraphID, allowsMirroring: Bool = false) throws -> Int {
        let access = access(allowsMirroring: allowsMirroring)
        if try GraphNativeIdentityColumns.validateModel(in: context) {
            guard try access.catalog(context).contains(graphID) else { throw GraphStoreError.missingGraph }
            return try access.validateAll(context, graphID: graphID)
        }
        guard try GraphTypedStoreAdapter.database.catalog(context).contains(graphID) else { throw GraphStoreError.missingGraph }
        let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
        for (id, node) in session.nodes { try session.validate(session.snapshot(node, id: id)) }
        return session.nodes.count
    }
}
