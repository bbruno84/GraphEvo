import Foundation
import GraphEvoRuntime
@_exported public import GraphEvoStore

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

public typealias GraphDatabase = GraphEvoStore.GraphDatabase

extension GraphDatabase {
    /// Opens a local multi-graph database without inventing a graph when the catalog is empty.
    public static func open(at url: URL) async throws -> GraphDatabase {
        try await open(configuration: .init(location: .sqlite(url)), schema: GraphRuntimeSchema.current,
                       adapter: GraphTypedStoreAdapter.database)
    }

    public static func inMemory() async throws -> GraphDatabase {
        try await open(configuration: .init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current,
                       adapter: GraphTypedStoreAdapter.database)
    }

    /// Explicit backed-up protocol upgrade. Native schema and application IDs remain unchanged.
    public static func upgradeLocalA3Store(at url: URL, backupRoot: URL) async throws -> GraphDatabase {
        guard url.isFileURL, backupRoot.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw GraphStoreError.legacyStoreRequiresAdoption
        }
        let database = try await open(configuration: .init(location: .sqlite(url)), schema: GraphRuntimeSchema.current,
            adapter: GraphTypedStoreAdapter.database, allowLegacyLayout: true)
        do { _ = try await database.upgrade(backupRoot: backupRoot); return database }
        catch { try await database.close(); throw error }
    }
}


/// Alpha native-model selection. Incompatible layouts require fresh stores, not automatic conversion.
public enum GraphDatabaseSchema: Sendable {
    case current
    /// S03: indexed native identities retained on deletion; application data is consumer-owned.
    /// Select explicitly for local or mirrored stores; this is not a data-migration gate.
    case nativeIdentity
}

extension GraphDatabase {
    /// Opens a fresh or compatible local store with an explicit native schema.
    public static func open(at url: URL, schema: GraphDatabaseSchema) async throws -> GraphDatabase {
        switch schema {
        case .current: return try await open(at: url)
        case .nativeIdentity:
            return try await open(configuration: .init(location: .sqlite(url)), schema: GraphRuntimeSchema.nativeIdentity,
                                  adapter: GraphNativeIdentityDatabaseAdapter.database)
        }
    }

    public static func inMemory(schema: GraphDatabaseSchema) async throws -> GraphDatabase {
        switch schema {
        case .current: return try await inMemory()
        case .nativeIdentity:
            return try await open(configuration: .init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.nativeIdentity,
                                  adapter: GraphNativeIdentityDatabaseAdapter.database)
        }
    }

    /// Checks the graph's current local storage identities, structure and payloads; returns application row count.
    /// Does not invoke application model decoders or certify CloudKit/import completion.
    public func validateIntegrity(of graphID: GraphID) async throws -> Int {
        try await contextRead { try GraphNativeIdentityDatabaseAdapter.validate($0, graphID: graphID, allowsMirroring: true) }
    }
}


extension GraphDatabase {
    /// Reads an existing local store without starting CloudKit or creating a graph/store.
    /// The containing app owns synchronization. This does not certify account access or import completion.
    public static func openReadOnly(at url: URL, schema: GraphDatabaseSchema = .current) async throws -> GraphDatabase {
        try await openReadOnly(configuration: .init(location: .sqlite(url), access: .readOnly), schema: schema)
    }

    /// Reads both existing resources locally; private/shared routing is retained without a cloud container.
    public static func openReadOnly(privateStoreAt privateURL: URL, sharedStoreAt sharedURL: URL,
                                    schema: GraphDatabaseSchema = .current) async throws -> GraphDatabase {
        try await openReadOnly(configuration: .init(location: .sqlite(privateURL), access: .readOnly,
                                                    sharedStoreURL: sharedURL), schema: schema)
    }

    private static func openReadOnly(configuration: StoreConfiguration, schema: GraphDatabaseSchema) async throws -> GraphDatabase {
        switch schema {
        case .current:
            return try await open(configuration: configuration, schema: GraphRuntimeSchema.current,
                                  adapter: GraphTypedStoreAdapter.database)
        case .nativeIdentity:
            return try await open(configuration: configuration, schema: GraphRuntimeSchema.nativeIdentity,
                                  adapter: GraphNativeIdentityDatabaseAdapter.database)
        }
    }
}
