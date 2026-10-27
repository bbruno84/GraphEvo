import Foundation
import GraphEvoRuntime
import GraphEvoStore

public typealias GraphStore = GraphEvoStore.GraphStore
public typealias GraphReadScope = GraphEvoStore.GraphReadScope
public typealias GraphMutation = GraphEvoStore.GraphMutation
public typealias GraphStoreError = GraphEvoStore.GraphStoreError
public typealias GraphV1AdoptionReport = GraphEvoStore.GraphV1AdoptionReport

extension GraphStore {
    /// Opens one local graph in the candidate schema. Populated v1 stores require explicit adoption.
    public static func open(at url: URL) async throws -> GraphStore {
        try await open(configuration: .init(location: .sqlite(url)), schema: GraphRuntimeSchema.current,
                       adapter: GraphTypedStoreAdapter.current).0
    }

    /// Creates a fresh independently identified in-memory graph.
    public static func inMemory() async throws -> GraphStore {
        try await open(configuration: .init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current,
                       adapter: GraphTypedStoreAdapter.current).0
    }

    /// Adopts a quiescent current-schema local v1 store, preserving its properties and references.
    /// The caller must stop all external/v1 writers. This is not a cloud cutover protocol.
    public static func adoptLocalV1Store(at url: URL, backupRoot: URL) async throws -> (store: GraphStore, report: GraphV1AdoptionReport) {
        guard FileManager.default.fileExists(atPath: url.path), backupRoot.isFileURL else {
            throw GraphStoreError.legacyStoreRequiresAdoption
        }
        let (store, report) = try await open(configuration: .init(location: .sqlite(url)), schema: GraphRuntimeSchema.current,
            adapter: GraphTypedStoreAdapter.current, adoptionBackupRoot: backupRoot)
        return (store, report)
    }
}
