import CoreData
import Foundation
import GraphEvoModel

package struct GraphMigrationWorkspaceLimits: Sendable {
    package let maximumTransactions: Int
    package let maximumNativeChanges: Int
    package let maximumLogicalChanges: Int
    package let maximumEncodedBytes: Int
    package init(maximumTransactions: Int = 4096, maximumNativeChanges: Int = 100_000,
                 maximumLogicalChanges: Int = 10_000, maximumEncodedBytes: Int = 4 * 1024 * 1024) {
        self.maximumTransactions = maximumTransactions; self.maximumNativeChanges = maximumNativeChanges
        self.maximumLogicalChanges = maximumLogicalChanges; self.maximumEncodedBytes = maximumEncodedBytes
    }
    package func validate() throws {
        guard (1...100_000).contains(maximumTransactions), (1...1_000_000).contains(maximumNativeChanges),
              (1...100_000).contains(maximumLogicalChanges), (1...8 * 1024 * 1024).contains(maximumEncodedBytes) else {
            throw GraphMigrationWorkspaceError.invalidLimit
        }
    }
}

package enum GraphMigrationPrimitive: String, Codable, Sendable { case entity, relationship, action }
package struct GraphMigrationChange: Codable, Sendable, Equatable {
    package let id: GraphNodeID
    package let kind: GraphMigrationPrimitive
    package let operation: GraphSyncOperation
    package init(id: GraphNodeID, kind: GraphMigrationPrimitive, operation: GraphSyncOperation) {
        self.id = id; self.kind = kind; self.operation = operation
    }
}

/// A bounded identity/operation manifest, never a snapshot of application/file payloads.
package struct GraphMigrationChangeSet: Codable, Sendable, Equatable {
    package let format: Int
    package let workspaceID: UUID
    package let graphID: GraphID
    package let baseline: GraphMigrationBoundary
    package let end: GraphMigrationBoundary
    package let changes: [GraphMigrationChange]
    package init(workspaceID: UUID, graphID: GraphID, baseline: GraphMigrationBoundary,
                 end: GraphMigrationBoundary, changes: [GraphMigrationChange]) {
        self.format = 1; self.workspaceID = workspaceID; self.graphID = graphID
        self.baseline = baseline; self.end = end; self.changes = changes
    }
}

/// Facade-owned history reconstruction, validation and authoritative native sealing.
package struct GraphMigrationWorkspaceAdapter: Sendable {
    package let validateSource: @Sendable (NSManagedObjectContext, GraphID, GraphMigrationBoundary) throws -> Void
    package let inspect: @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationWorkspaceLimits) throws -> GraphMigrationChangeSet?
    package let seal: @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationWorkspaceLimits) throws -> GraphMigrationChangeSet
    package init(validateSource: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphMigrationBoundary) throws -> Void = { _, _, _ in throw GraphMigrationWorkspaceError.unavailable },
                 inspect: @escaping @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationWorkspaceLimits) throws -> GraphMigrationChangeSet?,
                 seal: @escaping @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationWorkspaceLimits) throws -> GraphMigrationChangeSet) {
        self.inspect = inspect; self.seal = seal; self.validateSource = validateSource
    }
}

/// Native tokens remain scoped to the context. No private token serialization is interpreted.
package enum GraphMigrationHistory {
    package static func token(_ data: Data) throws -> NSPersistentHistoryToken {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data) else {
            throw GraphMigrationWorkspaceError.historyUnavailable
        }
        return value
    }
    package static func transactions(_ context: NSManagedObjectContext, after token: NSPersistentHistoryToken?,
                                     maximum: Int, author: String? = nil) throws -> [NSPersistentHistoryTransaction] {
        guard maximum > 0, maximum <= 100_001, let fetch = NSPersistentHistoryTransaction.fetchRequest else {
            throw GraphMigrationWorkspaceError.historyUnavailable
        }
        fetch.fetchLimit = maximum
        if let author { fetch.predicate = NSPredicate(format: "author == %@", author) }
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        request.fetchRequest = fetch; request.resultType = .transactionsOnly
        request.affectedStores = context.persistentStoreCoordinator?.persistentStores
        do {
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let rows = result.result as? [NSPersistentHistoryTransaction] else { throw GraphMigrationWorkspaceError.historyUnavailable }
            return rows.sorted { $0.transactionNumber < $1.transactionNumber }
        } catch { throw GraphMigrationWorkspaceError.historyUnavailable }
    }
    package static func validateSource(_ context: NSManagedObjectContext, boundary: GraphMigrationBoundary) throws {
        let current = try GraphMigrationBoundary.capture(context)
        guard current.storeID == boundary.storeID else { throw GraphMigrationWorkspaceError.staleSource }
        let start = try token(boundary.token)
        let rows = try transactions(context, after: start, maximum: 4097)
        guard rows.count <= 4096 else { throw GraphMigrationWorkspaceError.historyLimit }
        guard rows.allSatisfy({ $0.storeID == current.storeID && $0.author == "GraphEvo.v2.syncMetadata" }) else {
            throw GraphMigrationWorkspaceError.staleSource
        }
        let last = try rows.last.map { try NSKeyedArchiver.archivedData(withRootObject: $0.token, requiringSecureCoding: true) } ?? boundary.token
        guard try token(last).isEqual(token(current.token)) else { throw GraphMigrationWorkspaceError.historyUnavailable }
    }
}
