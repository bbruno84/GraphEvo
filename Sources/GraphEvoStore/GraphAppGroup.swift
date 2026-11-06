import Foundation
import GraphEvoModel
import GraphEvoRuntime
import os

/// Access to a dedicated graph in an entitled App Group container.
public struct GraphAppGroupConfiguration: Sendable {
    public enum Role: Sendable { case primary, secondary }
    public enum SecondaryAccess: Sendable { case readOnly, readWrite }

    public let identifier: String
    public let role: Role
    public let secondaryAccess: SecondaryAccess
    public let diagnosticLabel: String?
    /// Lets the primary connect and open synchronized graphs in this App Group.
    public let allowsCloudSynchronization: Bool

    /// The label is used only in diagnostics. Secondary access applies only to the secondary role.
    public init(identifier: String, role: Role, secondaryAccess: SecondaryAccess = .readOnly,
                diagnosticLabel: String? = nil, allowsCloudSynchronization: Bool = false) {
        self.identifier = identifier
        self.role = role
        self.secondaryAccess = secondaryAccess
        self.diagnosticLabel = diagnosticLabel
        self.allowsCloudSynchronization = allowsCloudSynchronization
    }
}

/// The result of a completed scoped operation, including whether native detach remains pending.
public struct GraphAppGroupOperationResult<Value: Sendable>: Sendable {
    public let value: Value
    public let closePending: Bool
}

private let appGroupLogger = Logger(subsystem: "GraphEvo", category: "AppGroup")

@available(iOS 17, macOS 14, *)
extension GraphContext {
    /// Creates a new App Group graph from the primary context.
    public func createAppGroupGraph(id: GraphID, conflictPolicy: GraphConflictPolicy = .lastEditWins) async throws -> GraphStore {
        let group = try requireAppGroup(.primary)
        return await retained(try await manager.createGraph(id: id, at: group.storeURL(for: id.rawValue), conflictPolicy: conflictPolicy))
    }

    /// Opens an existing App Group graph from the primary context.
    public func openAppGroupGraph(id: GraphID) async throws -> GraphStore {
        let group = try requireAppGroup(.primary)
        if manager.publicAppGroup?.allowsCloudSynchronization == true { await prepareMonitoring() }
        return await retained(try await manager.openGraph(id: id, at: group.storeURL(for: id.rawValue)))
    }

    /// Performs a generation-pinned read and releases the secondary lease.
    public func readAppGroupGraph<Value: Sendable>(id: GraphID,
        _ body: @escaping @Sendable (GraphReadScope) throws -> Value
    ) async throws -> GraphAppGroupOperationResult<Value> {
        let account = manager.adapter.account
        return try await withSecondaryGraph(id: id) { graph in
            try await graph.read { scope in
                try scope.withContext { context, adapter in
                    if let participant = try adapter.participantAccess?(context, id, nil) {
                        throw participant.blocked ? GraphStoreError.resourceReserved : GraphStoreError.accountIsolated
                    }
                    guard try account?.read(context, id) == nil else { throw GraphStoreError.accountIsolated }
                }
                return try body(scope)
            }
        }
    }

    /// Commits one opted-in secondary transaction and releases its lease.
    public func transactionAppGroupGraph<Value: Sendable>(id: GraphID,
        _ body: @escaping @Sendable (GraphMutation) throws -> Value
    ) async throws -> GraphAppGroupOperationResult<Value> {
        _ = try requireAppGroup(.secondary)
        guard manager.publicAppGroup?.secondaryAccess == .readWrite else { throw GraphStoreError.readOnly }
        return try await withSecondaryGraph(id: id) { try await $0.transaction(body) }
    }

    private func withSecondaryGraph<Value: Sendable>(id: GraphID,
        _ operation: (GraphStore) async throws -> Value
    ) async throws -> GraphAppGroupOperationResult<Value> {
        let group = try requireAppGroup(.secondary)
        let graph = try await manager.openGraph(id: id, at: group.storeURL(for: id.rawValue))
        let value: Value
        do { value = try await operation(graph) }
        catch {
            _ = await closeSecondaryGraph(graph)
            throw error
        }
        return .init(value: value, closePending: await closeSecondaryGraph(graph))
    }

    private func closeSecondaryGraph(_ graph: GraphStore) async -> Bool {
        do {
            try await graph.close()
            return false
        } catch {
            let label = manager.publicAppGroup?.diagnosticLabel ?? "secondary"
            appGroupLogger.error("Native App Group detach pending for \(label, privacy: .private)")
            return true
        }
    }

    private func requireAppGroup(_ role: GraphAppGroupConfiguration.Role) throws -> AppGroupStoreLocation {
        guard let group = manager.appGroup, let configuration = manager.publicAppGroup else {
            throw GraphStoreError.unsupportedLayout
        }
        guard configuration.role == role else { throw GraphStoreError.permissionDenied }
        return group
    }

    func requireOrdinaryContext() throws {
        guard let configuration = manager.publicAppGroup else { return }
        throw configuration.role == .secondary ? GraphStoreError.permissionDenied : GraphStoreError.unsupportedLayout
    }
}
