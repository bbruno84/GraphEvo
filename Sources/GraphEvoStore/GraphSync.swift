import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package enum GraphSyncOperation: String, Codable, Sendable { case save, delete }

/// Local discovery metadata, never a consumer format/version declaration.
package struct GraphSyncChange: Codable, Equatable, Sendable {
    package let id: GraphNodeID
    package let nativeKind: String
    package let operation: GraphSyncOperation
    package let generation: Int64
    package init(id: GraphNodeID, nativeKind: String, operation: GraphSyncOperation, generation: Int64) {
        self.id = id; self.nativeKind = nativeKind; self.operation = operation; self.generation = generation
    }
}

package struct GraphSyncItem: Sendable, Equatable {
    package let change: GraphSyncChange
    package let record: GraphRecord?
    package init(change: GraphSyncChange, record: GraphRecord?) { self.change = change; self.record = record }
}

package struct GraphSyncPrepared: Sendable {
    package let epoch: UUID
    package let items: [GraphSyncItem]
    package init(epoch: UUID, items: [GraphSyncItem]) { self.epoch = epoch; self.items = items }
}

package struct GraphSyncBatch: Sendable {
    package let id: UUID
    package let graphID: GraphID
    package let items: [GraphSyncItem]
    let epoch: UUID
}

package enum GraphSyncError: Error {
    case unavailable, busy, invalidLimit, invalidState, historyUnavailable
    case historyLimit, pendingLimit, unknownAuthor, unresolvedChange, staleBatch, pendingImport
}

/// Queue/count limits are not total SQL-I/O, heap or attachment-size bounds.
package struct GraphSyncLimits: Sendable {
    package let maximumTransactions: Int
    package let maximumChanges: Int
    package let maximumPending: Int
    package init(maximumTransactions: Int = 4096, maximumChanges: Int = 100_000, maximumPending: Int = 10_000) {
        self.maximumTransactions = maximumTransactions; self.maximumChanges = maximumChanges; self.maximumPending = maximumPending
    }
}

/// All callbacks stay on the runtime writer context; native save belongs to StoreResources.
package struct GraphSyncAdapter: Sendable {
    package let collect: @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits) throws -> Int
    package let prepare: @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits, Int) throws -> GraphSyncPrepared
    package let acknowledge: @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits, UUID, [GraphSyncChange]) throws -> Int
    package let importPatches: @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits, [GraphRecordPatch]) throws -> Void
    package init(
        collect: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits) throws -> Int,
        prepare: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits, Int) throws -> GraphSyncPrepared,
        acknowledge: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits, UUID, [GraphSyncChange]) throws -> Int,
        importPatches: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphSyncLimits, [GraphRecordPatch]) throws -> Void
    ) {
        self.collect = collect; self.prepare = prepare; self.acknowledge = acknowledge; self.importPatches = importPatches
    }
}

/// Demand-driven discovery and one in-memory attempt per graph. Transport is not activated here.
actor GraphSyncSession {
    private let graphID: GraphID
    private let handle: StoreHandle
    private let adapter: GraphSyncAdapter
    private var busy = false
    private var active: GraphSyncBatch?
    private var retired = false

    init(graphID: GraphID, handle: StoreHandle, adapter: GraphSyncAdapter) {
        self.graphID = graphID; self.handle = handle; self.adapter = adapter
    }

    private func begin() throws {
        guard !retired else { throw GraphStoreError.closed }
        guard !busy else { throw GraphSyncError.busy }
        busy = true
    }

    func collect(limits: GraphSyncLimits) async throws -> Int {
        try begin(); defer { busy = false }
        let adapter = adapter, graphID = graphID
        return try await handle.transaction { try adapter.collect($0, graphID, limits) }
    }

    func prepare(maximumRecords: Int, limits: GraphSyncLimits) async throws -> GraphSyncBatch {
        guard maximumRecords > 0 else { throw GraphSyncError.invalidLimit }
        guard active == nil else { throw GraphSyncError.busy }
        try begin(); defer { busy = false }
        let adapter = adapter, graphID = graphID
        let prepared = try await handle.transaction { try adapter.prepare($0, graphID, limits, maximumRecords) }
        guard !retired else { throw GraphStoreError.closed }
        let batch = GraphSyncBatch(id: UUID(), graphID: graphID, items: prepared.items, epoch: prepared.epoch)
        active = batch
        return batch
    }

    func acknowledge(_ id: UUID, succeeded: Set<GraphNodeID>, limits: GraphSyncLimits) async throws -> Int {
        guard let batch = active, batch.id == id,
              succeeded.isSubset(of: Set(batch.items.map { $0.change.id })) else { throw GraphSyncError.staleBatch }
        try begin(); defer { busy = false }
        let adapter = adapter, graphID = graphID
        let changes = batch.items.map(\.change).filter { succeeded.contains($0.id) }
        let removed = try await handle.transaction { try adapter.acknowledge($0, graphID, limits, batch.epoch, changes) }
        active = nil
        return removed
    }

    func abandon(_ id: UUID) throws {
        guard !busy else { throw GraphSyncError.busy }
        guard active?.id == id else { throw GraphSyncError.staleBatch }
        active = nil
    }

    func importPatches(_ patches: [GraphRecordPatch], limits: GraphSyncLimits) async throws {
        try begin(); defer { busy = false }
        let adapter = adapter, graphID = graphID
        try await handle.transaction { try adapter.importPatches($0, graphID, limits, patches) }
    }

    func retire() { retired = true; active = nil }
}
