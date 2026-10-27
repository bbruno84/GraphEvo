import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// The graph catalog and structural membership operations supplied by the native facade adapter.
package struct GraphDatabaseAdapter: Sendable {
    package let graph: GraphStoreAdapter
    package let catalog: @Sendable (NSManagedObjectContext) throws -> [GraphID]
    package let create: @Sendable (NSManagedObjectContext, GraphID) throws -> Void
    package let upgrade: @Sendable (NSManagedObjectContext, URL) throws -> [GraphID]

    package init(graph: GraphStoreAdapter,
                 catalog: @escaping @Sendable (NSManagedObjectContext) throws -> [GraphID],
                 create: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> Void,
                 upgrade: @escaping @Sendable (NSManagedObjectContext, URL) throws -> [GraphID]) {
        self.graph = graph; self.catalog = catalog; self.create = create; self.upgrade = upgrade
    }
}

/// Owns a resource lease and opens independently closeable logical graphs in that resource.
public actor GraphDatabase {
    private let handle: StoreHandle
    private let adapter: GraphDatabaseAdapter

    private init(handle: StoreHandle, adapter: GraphDatabaseAdapter) {
        self.handle = handle; self.adapter = adapter
    }

    package static func open(configuration: StoreConfiguration, schema: StoreSchema,
                             adapter: GraphDatabaseAdapter, allowLegacyLayout: Bool = false) async throws -> GraphDatabase {
        let handle: StoreHandle
        do { handle = try await StoreRegistry.shared.open(configuration, schema: schema) }
        catch { throw GraphStore.translate(error) }
        do {
            if !allowLegacyLayout { _ = try await handle.read(adapter.catalog) }
            return GraphDatabase(handle: handle, adapter: adapter)
        } catch { try await handle.close(); throw GraphStore.translate(error) }
    }

    public func graphIDs() async throws -> [GraphID] {
        do { return try await handle.read(adapter.catalog) }
        catch { throw GraphStore.translate(error) }
    }

    public func createGraph() async throws -> GraphStore {
        let id = GraphID(), adapter = adapter
        let lease: StoreHandle
        do { lease = try await handle.newLease() }
        catch { throw GraphStore.translate(error) }
        do {
            try await lease.transaction { try adapter.create($0, id) }
            // Do not add a cancellable read after a successful creation commit.
            return GraphStore.attached(id: id, handle: lease, adapter: adapter.graph)
        } catch {
            try await lease.close()
            throw GraphStore.translate(error)
        }
    }

    public func openGraph(_ id: GraphID) async throws -> GraphStore {
        guard try await graphIDs().contains(id) else { throw GraphStoreError.missingGraph }
        let lease: StoreHandle
        do { lease = try await handle.newLease() }
        catch { throw GraphStore.translate(error) }
        return GraphStore.attached(id: id, handle: lease, adapter: adapter.graph)
    }

    /// Privileged native operations share the same admission and writer ownership as typed edits.
    package func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        do { return try await handle.nativeOperation(body) }
        catch { throw GraphStore.translate(error) }
    }

    public func close() async throws {
        do { try await handle.close() } catch { throw GraphStore.translate(error) }
    }

    package func upgrade(backupRoot: URL) async throws -> [GraphID] {
        let adapter = adapter
        return try await handle.transaction { try adapter.upgrade($0, backupRoot) }
    }
}
