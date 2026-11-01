import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package enum GraphMigrationWorkspaceError: Error, Equatable {
    case unavailable
    case invalidDestination
    case invalidWorkspace
    case historyUnavailable
    case participantUnsupported
}

/// The stage is retained if native detachment or ownership-safe cleanup fails.
package struct GraphMigrationWorkspaceCleanupFailure: Error {
    package let directory: URL
    package let preparationFailure: any Error
    package let cleanupFailure: any Error
}

/// A fresh native history cut. It is meaningful only with the descriptor's purpose identity.
package struct GraphMigrationBoundary: Codable, Sendable, Equatable {
    package let storeID: String
    package let transaction: Int64?
    package let token: Data

    static func capture(_ context: NSManagedObjectContext, after prior: Self? = nil) throws -> Self {
        guard let coordinator = context.persistentStoreCoordinator,
              coordinator.persistentStores.count == 1, let store = coordinator.persistentStores.first,
              let storeID = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String,
              let current = coordinator.currentPersistentHistoryToken(fromStores: [store]) else {
            throw GraphMigrationWorkspaceError.historyUnavailable
        }
        let token = try NSKeyedArchiver.archivedData(withRootObject: current, requiringSecureCoding: true)
        guard token.count <= 64 * 1024 else { throw GraphMigrationWorkspaceError.historyUnavailable }
        var number: Int64?
        if let prior {
            guard prior.storeID == storeID,
                  let start = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: prior.token) else {
                throw GraphMigrationWorkspaceError.historyUnavailable
            }
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: start)
            request.resultType = .transactionsOnly
            request.affectedStores = [store]
            // Preparation admits exactly one setup save and no consumer writes. Do not sort
            // history using native implementation fields or substitute wall-clock ordering.
            guard let fetch = NSPersistentHistoryTransaction.fetchRequest else { throw GraphMigrationWorkspaceError.historyUnavailable }
            fetch.fetchLimit = 2
            request.fetchRequest = fetch
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction],
                  transactions.count == 1, let setup = transactions.first,
                  setup.storeID == storeID, setup.transactionNumber > 0, setup.token.isEqual(current) else {
                throw GraphMigrationWorkspaceError.historyUnavailable
            }
            number = setup.transactionNumber
        }
        return Self(storeID: storeID, transaction: number, token: token)
    }
}

/// No URLs, accounts, pending cloud work or opaque engine state are serialized here.
package struct GraphMigrationWorkspaceDescriptor: Codable, Sendable, Equatable {
    package let format: Int
    package let id: UUID
    package let graphID: GraphID
    package let schema: String
    package let storePath: String
    package let source: GraphMigrationBoundary
    package let baseline: GraphMigrationBoundary
}

/// An isolated editable graph. Sealing, restart activation and publication are subsequent increments.
package actor GraphMigrationWorkspace {
    package nonisolated let id: UUID
    package nonisolated let graph: GraphStore
    package nonisolated let descriptor: GraphMigrationWorkspaceDescriptor
    package nonisolated let directory: URL
    private let handle: StoreHandle
    private let sourceHold: StoreReservation
    private let storeOwnership: WorkspaceFileIdentity
    private let ownership: WorkspaceDirectoryIdentity
    private var closing: Task<Void, any Error>?
    private var discarding: Task<Void, any Error>?

    init(graph: GraphStore, handle: StoreHandle, descriptor: GraphMigrationWorkspaceDescriptor,
         directory: URL, sourceHold: StoreReservation, ownership: WorkspaceDirectoryIdentity, storeOwnership: WorkspaceFileIdentity) {
        self.id = descriptor.id; self.graph = graph; self.handle = handle
        self.descriptor = descriptor; self.directory = directory; self.sourceHold = sourceHold
        self.ownership = ownership; self.storeOwnership = storeOwnership
    }

    /// End all working access and release only this migration's original-store holds; retain files.
    package func close() async throws {
        if let closing { return try await closing.value }
        let graph = graph, handle = handle, sourceHold = sourceHold
        let task = Task {
            try await handle.setDataAvailable(false, terminal: true)
            try await graph.close()
            try await handle.close()
            await sourceHold.release()
        }
        closing = task
        do { try await task.value }
        catch { closing = nil; throw error }
    }

    /// Destruction is explicit and follows successful native detachment and ownership validation.
    package func discard() async throws {
        if let discarding { return try await discarding.value }
        let directory = directory, descriptor = descriptor, ownership = ownership, storeOwnership = storeOwnership
        let task = Task {
            try await self.close()
            try WorkspaceFiles.remove(directory, descriptor: descriptor, ownership: ownership, storeOwnership: storeOwnership)
        }
        discarding = task
        do { try await task.value }
        catch { discarding = nil; throw error }
    }

    deinit {
        guard closing == nil else { return }
        let graph = graph, handle = handle, hold = sourceHold
        Task {
            do {
                try await handle.setDataAvailable(false, terminal: true)
                try await graph.close(); try await handle.close()
                await hold.release()
            } catch { /* Retain native registry claims and working files on failed detachment. */ }
        }
    }
}

extension GraphContextManager {
    /// Protect the original and return a complete, explicitly non-syncing editable copy.
    package func prepareMigrationWorkspace(for id: GraphID, at destination: URL) async throws -> GraphMigrationWorkspace {
        guard let prepare = adapter.prepareWorkspace, let validate = adapter.validateBackup,
              let location = locations[id] else { throw GraphMigrationWorkspaceError.unavailable }
        let destination = try WorkspaceFiles.destination(destination, source: location.url)
        let retained = try await openGraph(id: id, at: location.url)
        var cloud: StoreReservation?, writes: StoreReservation?, maintenance: StoreReservation?
        var working: StoreHandle?
        var stage: URL?
        var stageOwnership: WorkspaceDirectoryIdentity?
        var published = false
        do {
            guard let entry = entries[id] else { throw GraphStoreError.closed }
            let owner = try await entry.opening.value
            cloud = try await reserveCloudPause(for: id)
            writes = try await owner.suspendLocalWrites()
            guard try await owner.participantAccess() == nil else { throw GraphMigrationWorkspaceError.participantUnsupported }
            let source = try await owner.migrationBoundary()
            let workspaceID = UUID()
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".workspace-" + workspaceID.uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            stage = staging
            let stagingOwnership = try WorkspaceDirectoryIdentity(staging)
            stageOwnership = stagingOwnership
            try workspaceID.uuidString.data(using: .utf8)!.write(to: staging.appendingPathComponent("owner"), options: .withoutOverwriting)
            let store = staging.appendingPathComponent("Graph.sqlite")
            maintenance = try await owner.reserveMaintenance()
            try await owner.copyStore(to: store, reservation: maintenance!)
            await maintenance?.release(); maintenance = nil
            try Task.checkCancellation()
            // Only detached, private staging files are marked through the native metadata API.
            try WorkspaceFiles.mark(store, workspaceID: workspaceID, graphID: id)
            let configuration = StoreConfiguration(location: .sqlite(store), exclusiveGraphID: id.rawValue, workspaceID: workspaceID)
            let handle = try await registry.open(configuration, schema: schema)
            working = handle
            let adapter = adapter
            let beforeSetup = try await handle.controlRead { try GraphMigrationBoundary.capture($0) }
            try await handle.transaction { context in
                try adapter.initialize(context, id, false)
                try prepare(context, id)
                try validate(context, id)
            }
            let baseline = try await handle.controlRead { try GraphMigrationBoundary.capture($0, after: beforeSetup) }
            let descriptor = GraphMigrationWorkspaceDescriptor(format: 1, id: workspaceID, graphID: id,
                schema: schema.identifier, storePath: "Graph.sqlite", source: source, baseline: baseline)
            let bytes = try JSONEncoder().encode(descriptor)
            guard bytes.count <= WorkspaceFiles.descriptorLimit else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            try bytes.write(to: staging.appendingPathComponent("workspace.json"), options: .withoutOverwriting)
            try await handle.close(); working = nil
            try Task.checkCancellation()
            guard try WorkspaceDirectoryIdentity(staging) == stagingOwnership else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            // moveItem refuses an occupied destination. Neither attached stores nor originals are moved.
            try FileManager.default.moveItem(at: staging, to: destination)
            published = true
            let final = try await registry.open(.init(location: .sqlite(destination.appendingPathComponent(descriptor.storePath)),
                exclusiveGraphID: id.rawValue, workspaceID: workspaceID), schema: schema)
            working = final
            try await final.read { context in
                try adapter.initialize(context, id, false)
                let current = try GraphMigrationBoundary.capture(context)
                guard current.storeID == baseline.storeID, current.token == baseline.token else { throw GraphMigrationWorkspaceError.historyUnavailable }
            }
            try Task.checkCancellation()
            let ownership = try WorkspaceDirectoryIdentity(destination)
            let storeOwnership = try WorkspaceFileIdentity(destination.appendingPathComponent(descriptor.storePath))
            let graph = GraphStore.attached(id: id, handle: try await final.newLease(), adapter: adapter.graph)
            let heldCloud = cloud!, heldWrites = writes!
            let hold = StoreReservation(id: workspaceID) {
                await heldWrites.release(); await heldCloud.release(); try? await retained.close()
            }
            return GraphMigrationWorkspace(graph: graph, handle: final, descriptor: descriptor,
                directory: destination, sourceHold: hold, ownership: ownership,
                storeOwnership: storeOwnership)
        } catch {
            let original = error
            // Never remove an attached stage, even if native cleanup itself failed.
            var cleanupFailure: (any Error)?
            // A failed open can retain a native owner without returning a StoreHandle.
            if case StoreRuntimeError.shutdownFailed = original { cleanupFailure = original }
            if let working { do { try await working.close() } catch { cleanupFailure = error } }
            if cleanupFailure == nil, !published, let stage, let stageOwnership {
                do {
                    guard try WorkspaceDirectoryIdentity(stage) == stageOwnership else { throw GraphMigrationWorkspaceError.invalidWorkspace }
                    try FileManager.default.removeItem(at: stage)
                } catch { cleanupFailure = error }
            }
            await maintenance?.release(); await writes?.release(); await cloud?.release()
            do { try await retained.close() } catch { if cleanupFailure == nil { cleanupFailure = error } }
            if let cleanupFailure {
                throw GraphMigrationWorkspaceCleanupFailure(directory: published ? destination : (stage ?? destination),
                    preparationFailure: original, cleanupFailure: cleanupFailure)
            }
            throw original
        }
    }
}

struct WorkspaceDirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw GraphMigrationWorkspaceError.invalidWorkspace
        }
        self.device = device.uint64Value; self.inode = inode.uint64Value
    }
}

struct WorkspaceFileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw GraphMigrationWorkspaceError.invalidWorkspace
        }
        self.device = device.uint64Value; self.inode = inode.uint64Value
    }
}

private enum WorkspaceFiles {
    static let descriptorLimit = 256 * 1024
    static func destination(_ url: URL, source: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "localhost", url.query == nil, url.fragment == nil else {
            throw GraphMigrationWorkspaceError.invalidDestination
        }
        let result = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.standardizedFileURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: result.deletingLastPathComponent().path),
              !FileManager.default.fileExists(atPath: result.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: result.path)) == nil,
              !source.path.hasPrefix(result.path + "/"), source != result else { throw GraphMigrationWorkspaceError.invalidDestination }
        return result
    }
    static func mark(_ url: URL, workspaceID: UUID, graphID: GraphID) throws {
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        guard metadata[StoreNativeContext.workspaceKey] == nil,
              metadata[StoreNativeContext.historySyncGraphKey] as? String == graphID.rawValue.uuidString else {
            throw GraphMigrationWorkspaceError.invalidWorkspace
        }
        metadata[StoreNativeContext.workspaceKey] = workspaceID.uuidString
        try NSPersistentStoreCoordinator.setMetadata(metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: url, options: nil)
    }
    static func remove(_ directory: URL, descriptor: GraphMigrationWorkspaceDescriptor, ownership: WorkspaceDirectoryIdentity, storeOwnership: WorkspaceFileIdentity) throws {
        guard try WorkspaceDirectoryIdentity(directory) == ownership,
              try WorkspaceFileIdentity(directory.appendingPathComponent(descriptor.storePath)) == storeOwnership else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        // Bound traversal and reject links before authorizing recursive removal of an owned directory.
        var count = 0
        func check(_ url: URL, depth: Int) throws {
            count += 1
            guard count <= 100_000, depth <= 32 else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try check(child, depth: depth + 1) }
            case .typeRegular:
                guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            default: throw GraphMigrationWorkspaceError.invalidWorkspace
            }
        }
        try check(directory, depth: 0)
        let manifestURL = directory.appendingPathComponent("workspace.json")
        let size = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber
        let ownerSize = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("owner").path)[.size] as? NSNumber
        guard let size, size.intValue <= descriptorLimit, ownerSize?.intValue == 36,
              try Data(contentsOf: directory.appendingPathComponent("owner")) == Data(descriptor.id.uuidString.utf8),
              try JSONDecoder().decode(GraphMigrationWorkspaceDescriptor.self, from: Data(contentsOf: manifestURL)) == descriptor else {
            throw GraphMigrationWorkspaceError.invalidWorkspace
        }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
            at: directory.appendingPathComponent(descriptor.storePath))
        guard metadata[StoreNativeContext.workspaceKey] as? String == descriptor.id.uuidString,
              metadata[NSStoreUUIDKey] as? String == descriptor.baseline.storeID else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        try FileManager.default.removeItem(at: directory)
    }
}
