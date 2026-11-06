import CoreData
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
    /// Enables the private CloudKit App Group path for the selected environment.
    public let privateCloudEnvironment: GraphCloudEnvironment?

    /// The label is used only in diagnostics. Secondary access applies only to the secondary role.
    public init(identifier: String, role: Role, secondaryAccess: SecondaryAccess = .readOnly,
                diagnosticLabel: String? = nil, privateCloudEnvironment: GraphCloudEnvironment? = nil) {
        self.identifier = identifier
        self.role = role
        self.secondaryAccess = secondaryAccess
        self.diagnosticLabel = diagnosticLabel
        self.privateCloudEnvironment = privateCloudEnvironment
    }
}

/// The result of a completed scoped operation, including whether native detach remains pending.
public struct GraphAppGroupOperationResult<Value: Sendable>: Sendable {
    public let value: Value
    public let closePending: Bool
}

struct GraphAppGroupAccountVerifier: Sendable {
    let container: String?
    let verify: @Sendable () async throws -> GraphCloudAccountAvailability
    let observe: @Sendable (@escaping @Sendable () -> Void) -> GraphCloudAccountObservation
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
        await manager.setLocalAccountAdapter(adapterForBootstrap)
        return await retained(try await manager.openGraph(id: id, at: group.storeURL(for: id.rawValue)))
    }

    /// Performs a generation-pinned read and releases the secondary lease.
    public func readAppGroupGraph<Value: Sendable>(id: GraphID,
        _ body: @escaping @Sendable (GraphReadScope) throws -> Value
    ) async throws -> GraphAppGroupOperationResult<Value> {
        try await withSecondaryGraph(id: id) { try await $0.read(validating: $1, body) }
    }

    /// Commits one opted-in secondary transaction and releases its lease.
    public func transactionAppGroupGraph<Value: Sendable>(id: GraphID,
        _ body: @escaping @Sendable (GraphMutation) throws -> Value
    ) async throws -> GraphAppGroupOperationResult<Value> {
        _ = try requireAppGroup(.secondary)
        guard manager.publicAppGroup?.secondaryAccess == .readWrite else { throw GraphStoreError.readOnly }
        return try await withSecondaryGraph(id: id) { try await $0.transaction(validating: $1, body) }
    }

    private func withSecondaryGraph<Value: Sendable>(id: GraphID,
        _ operation: (GraphStore, @escaping @Sendable (NSManagedObjectContext) throws -> Void) async throws -> Value
    ) async throws -> GraphAppGroupOperationResult<Value> {
        let group = try requireAppGroup(.secondary)
        let verifiesCloud = manager.publicAppGroup?.privateCloudEnvironment != nil
        if verifiesCloud {
            guard secondaryScopes.insert(id).inserted else { throw GraphStoreError.resourceReserved }
        }
        defer { if verifiesCloud { secondaryScopes.remove(id) } }

        // Verify before registering a native owner. A suspended or killed
        // extension may otherwise leave an owner claim during the network call.
        let fence = OSAllocatedUnfairLock(initialState: (invalidated: false, control: Optional<StoreAccountControl>.none))
        let observation = secondaryAccountVerifier?.observe {
            let control = fence.withLock { state in
                state.invalidated = true
                return state.control
            }
            control?.update(.isolated(.verificationRequired), revision: 2)
        }
        defer { observation?.cancel() }
        let availability: GraphCloudAccountAvailability?
        do { availability = try await secondaryAccountVerifier?.verify() }
        catch is CancellationError { throw CancellationError() }
        catch { availability = nil }
        try Task.checkCancellation()

        let graph = try await manager.openGraph(id: id, at: group.storeURL(for: id.rawValue))
        let value: Value
        do {
            guard let entry = await manager.entries[id] else { throw GraphStoreError.closed }
            let owner = try await entry.opening.value
            let expected = try await owner.accountIdentity()
            let validate = await owner.scopedAccountCheck(expected)
            if let expected {
                guard let verifier = secondaryAccountVerifier, verifier.container == expected.container,
                      manager.publicAppGroup?.privateCloudEnvironment == expected.environment else {
                    throw GraphStoreError.accountIsolated
                }
                guard availability == .available(expected.account) else { throw GraphStoreError.accountIsolated }
                let control = try await owner.accountControl()
                let admitted = fence.withLock { state in
                    guard !state.invalidated else { return false }
                    state.control = control
                    return true
                }
                guard admitted else { throw GraphStoreError.accountIsolated }
                // A notification can invalidate the native permit before or during the scope.
                defer { control.update(.isolated(.verificationRequired), revision: 2) }
                control.update(.available, revision: 1)
                value = try await operation(graph, validate)
            } else {
                value = try await operation(graph, validate)
            }
        } catch {
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
