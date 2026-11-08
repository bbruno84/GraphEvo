import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// Durable progress of a definitive graph deletion, separate from participant leave.
public struct GraphDeletionStatus: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable { case prepared, remoteDeleted, completed }
    public let id: UUID
    public let graphID: GraphID
    public let phase: Phase
}

package struct GraphDeletionSource: Codable, Sendable, Equatable {
    package let device: UInt64
    package let inode: UInt64
    package init(_ url: URL) throws {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)
        guard value[.type] as? FileAttributeType == .typeRegular,
              let device = value[.systemNumber] as? NSNumber,
              let inode = value[.systemFileNumber] as? NSNumber else { throw GraphStoreError.ownershipConflict }
        self.device = device.uint64Value; self.inode = inode.uint64Value
    }
}

package struct GraphDeletionIntent: Codable, Sendable, Equatable {
    package var format = 1
    package let operationID: UUID
    package let graphID: GraphID
    package let storeID: String
    package let source: GraphDeletionSource
    package let binding: GraphCloudTransportBinding?
    package var allowsEmptyZone = false
    package var phase: GraphDeletionStatus.Phase
    var status: GraphDeletionStatus { .init(id: operationID, graphID: graphID, phase: phase) }
    package var valid: Bool { format == 1 && !storeID.isEmpty && (!allowsEmptyZone || binding != nil) && (binding.map { $0.route.graphID == graphID && $0.route.zone.scope == .private } ?? true) }
    package func matches(_ other: Self) -> Bool {
        operationID == other.operationID && graphID == other.graphID && storeID == other.storeID && source == other.source && binding == other.binding && allowsEmptyZone == other.allowsEmptyZone
    }
    static func read(_ config: StoreConfiguration) async throws -> Self? {
        guard config.workspaceID == nil, config.exclusiveGraphID != nil else { return nil }
        guard let bytes = try await StoreOperationJournal.read(config) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.valid, value.graphID.rawValue == config.exclusiveGraphID else { throw GraphCloudError.invalidState }
        return value
    }
    func persist(_ config: StoreConfiguration) async throws {
        let value = self
        _ = try await StoreOperationJournal.update(config) { bytes in
            if let bytes, !bytes.isEmpty {
                let prior = try JSONDecoder().decode(Self.self, from: bytes)
                guard prior.valid, prior.matches(value), Self.rank(prior.phase) <= Self.rank(value.phase) else { throw GraphCloudError.ownershipConflict }
            }
            return try JSONEncoder().encode(value)
        }
    }
    static func rank(_ phase: GraphDeletionStatus.Phase) -> Int {
        switch phase { case .prepared: 0; case .remoteDeleted: 1; case .completed: 2 }
    }
}

package struct GraphDeletionAdapter: Sendable {
    package let state: @Sendable (NSManagedObjectContext, GraphID, GraphDeletionIntent?) throws -> GraphDeletionIntent?
    package init(state: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphDeletionIntent?) throws -> GraphDeletionIntent?) { self.state = state }
}
