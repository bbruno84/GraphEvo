import Foundation
import GraphEvoRuntime
@_exported public import GraphEvoStore

public typealias GraphCloudAccountState = GraphEvoStore.GraphCloudAccountState
public typealias GraphStore = GraphEvoStore.GraphStore
public typealias GraphReadScope = GraphEvoStore.GraphReadScope
public typealias GraphMutation = GraphEvoStore.GraphMutation
public typealias GraphStoreError = GraphEvoStore.GraphStoreError
public typealias GraphRemovalError = GraphEvoStore.GraphRemovalError
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

/// An application-owned coordinated GraphEvo 2 entry, independent of legacy openers.
@available(iOS 17, macOS 14, *)
public typealias GraphContext = GraphEvoStore.GraphContext

public typealias GraphAppGroupConfiguration = GraphEvoStore.GraphAppGroupConfiguration
public typealias GraphAppGroupOperationResult<Value: Sendable> = GraphEvoStore.GraphAppGroupOperationResult<Value>

@available(iOS 17, macOS 14, *)
extension GraphContext {
    /// Creates an independent context using the production native adapters.
    public init() {
        self.init(manager: GraphContextManager(schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()))
    }

    /// Opens and creates local SQLite graphs with first-class files.
    public static func localFiles() -> GraphContext {
        GraphContext(manager: GraphContextManager(schema: GraphRuntimeSchema.localFiles,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()))
    }

    /// Creates a context restricted to the dedicated store paths in this App Group.
    public init(appGroup configuration: GraphAppGroupConfiguration) throws {
        let group: AppGroupStoreLocation
        do { group = try AppGroupStoreLocation(identifier: configuration.identifier) }
        catch { throw GraphStore.translate(error) }
        self.init(manager: GraphContextManager(schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID(), appGroup: group, publicAppGroup: configuration))
    }

    /// Creates a context for internal probes of the App Group runtime.
    package init(appGroupIdentifier: String) throws {
        let group = try AppGroupStoreLocation(identifier: appGroupIdentifier)
        self.init(manager: GraphContextManager(schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID(), appGroup: group))
    }
}

@available(iOS 17, macOS 14, *)
public typealias GraphCloudConnection = GraphEvoStore.GraphCloudConnection

public typealias GraphCloudConnectionConfiguration = GraphEvoStore.GraphCloudConnectionConfiguration

public typealias GraphCloudConnectionState = GraphEvoStore.GraphCloudConnectionState

public typealias GraphCloudConnectionFailure = GraphEvoStore.GraphCloudConnectionFailure

public typealias GraphCloudConnectionError = GraphEvoStore.GraphCloudConnectionError

public typealias GraphCloudScope = GraphEvoStore.GraphCloudScope

public typealias GraphCloudEnvironment = GraphEvoStore.GraphCloudEnvironment

public typealias GraphConflictPolicy = GraphEvoStore.GraphConflictPolicy

public typealias GraphV1BootstrapRequest = GraphEvoStore.GraphV1BootstrapRequest

public typealias GraphV1BootstrapResult = GraphEvoStore.GraphV1BootstrapResult

public typealias GraphV1BootstrapReceipt = GraphEvoStore.GraphV1BootstrapReceipt

public typealias GraphV1BootstrapConversion = GraphEvoStore.GraphV1BootstrapConversion

public typealias GraphCloudCutoverDeclaration = GraphEvoStore.GraphCloudCutoverDeclaration

public typealias GraphCloudActivationStatus = GraphEvoStore.GraphCloudActivationStatus

public typealias GraphCloudActivationPhase = GraphEvoStore.GraphCloudActivationPhase

public typealias GraphCloudActivationResult = GraphEvoStore.GraphCloudActivationResult

public typealias GraphCloudReplicaResult = GraphEvoStore.GraphCloudReplicaResult

public typealias GraphCloudActivationError = GraphEvoStore.GraphCloudActivationError

public typealias GraphCloudActivationCleanupFailure = GraphEvoStore.GraphCloudActivationCleanupFailure

public typealias GraphV1BootstrapError = GraphEvoStore.GraphStoreMigrationError

public typealias GraphCloudSharePermission = GraphEvoStore.GraphCloudSharePermission
public typealias GraphCloudSharingStatus = GraphEvoStore.GraphCloudSharingStatus
public typealias GraphCloudSharingPhase = GraphEvoStore.GraphCloudSharingPhase
public typealias GraphCloudSharingRole = GraphEvoStore.GraphCloudSharingRole
public typealias GraphCloudRemovalReason = GraphEvoStore.GraphCloudRemovalReason
public typealias GraphCloudParticipant = GraphEvoStore.GraphCloudParticipant
public typealias GraphCloudParticipantIdentity = GraphEvoStore.GraphCloudParticipantIdentity
public typealias GraphCloudDiscoveryError = GraphEvoStore.GraphCloudDiscoveryError
public typealias GraphCloudSharingError = GraphEvoStore.GraphCloudSharingError
public typealias GraphCloudJoinState = GraphEvoStore.GraphCloudJoinState
@available(iOS 17, macOS 14, *)
public typealias GraphCloudJoin = GraphEvoStore.GraphCloudJoin
@available(iOS 17, macOS 14, *)
public typealias GraphCloudSharingPresentation = GraphEvoStore.GraphCloudSharingPresentation
