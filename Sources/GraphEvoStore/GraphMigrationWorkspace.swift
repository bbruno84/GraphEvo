import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package enum GraphMigrationWorkspaceError: Error, Equatable {
    case unavailable
    case closed
    case sealed
    case invalidLimit
    case historyLimit
    case changeLimit
    case encodedLimit
    case staleSource
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

    package init(storeID: String, transaction: Int64?, token: Data) {
        self.storeID = storeID; self.transaction = transaction; self.token = token
    }
    package static func capture(_ context: NSManagedObjectContext, after prior: Self? = nil) throws -> Self {
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
    package let sourceFile: WorkspaceFileIdentity
    package let workingFile: WorkspaceFileIdentity
}

/// An isolated editable graph. Sealing, restart activation and publication are subsequent increments.
package actor GraphMigrationWorkspace {
    package nonisolated let id: UUID
    package nonisolated let graph: GraphStore
    package nonisolated let descriptor: GraphMigrationWorkspaceDescriptor
    package nonisolated let directory: URL
    private let handle: StoreHandle
    private let registry: StoreRegistry
    private let schema: StoreSchema
    private let activationID: UUID
    private var cleanupHandle: StoreHandle?
    private let workspaceAdapter: GraphMigrationWorkspaceAdapter?
    private var sealed: GraphMigrationChangeSet?
    private var sealHold: StoreReservation?
    private var sealing: Task<GraphMigrationChangeSet, any Error>?
    private let sourceHold: StoreReservation
    private let storeOwnership: WorkspaceFileIdentity
    private let ownership: WorkspaceDirectoryIdentity
    private var closing: Task<Void, any Error>?
    private var discarding: Task<Void, any Error>?

    init(graph: GraphStore, handle: StoreHandle, descriptor: GraphMigrationWorkspaceDescriptor,
         directory: URL, sourceHold: StoreReservation, ownership: WorkspaceDirectoryIdentity, storeOwnership: WorkspaceFileIdentity,
         adapter: GraphMigrationWorkspaceAdapter?, registry: StoreRegistry, schema: StoreSchema, activationID: UUID, sealed: GraphMigrationChangeSet? = nil, sealHold: StoreReservation? = nil) {
        self.id = descriptor.id; self.graph = graph; self.handle = handle
        self.descriptor = descriptor; self.directory = directory; self.sourceHold = sourceHold
        self.ownership = ownership; self.storeOwnership = storeOwnership
        self.registry = registry; self.schema = schema; self.activationID = activationID
        self.workspaceAdapter = adapter; self.sealed = sealed; self.sealHold = sealHold
    }

    /// Freeze one coherent PH cut and commit its authoritative seal in the same native transaction.
    package func seal(limits: GraphMigrationWorkspaceLimits = .init()) async throws -> GraphMigrationChangeSet {
        guard closing == nil, discarding == nil else { throw GraphMigrationWorkspaceError.closed }
        if let sealed { return sealed }
        if let sealing { return try await sealing.value }
        try limits.validate()
        guard let workspaceAdapter else { throw GraphMigrationWorkspaceError.unavailable }
        let handle = handle, descriptor = descriptor
        let task = Task<GraphMigrationChangeSet, any Error> {
            let writes = try await handle.suspendWrites()
            var maintenance: StoreReservation?
            do {
                maintenance = try await handle.reserveMaintenance()
                let value = try await handle.workspaceTransaction(reservation: maintenance!) {
                    try workspaceAdapter.seal($0, descriptor, limits)
                }
                // A committed seal is success; caller cancellation cannot reopen the working graph.
                self.didSeal(value, hold: writes)
                await maintenance?.release()
                return value
            } catch {
                await maintenance?.release(); await writes.release()
                throw error
            }
        }
        sealing = task
        // Forward cancellation only to this preparation attempt; never replay a consumer body.
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            sealing = nil; return result
        } catch { sealing = nil; throw error }
    }
    private func didSeal(_ result: GraphMigrationChangeSet, hold: StoreReservation) {
        sealed = result; sealHold = hold
    }

    /// End all working access and release only this migration's original-store holds; retain files.
    package func close() async throws {
        if let closing { return try await closing.value }
        let graph = graph, handle = handle, sourceHold = sourceHold, sealing = sealing
        let task = Task {
            _ = try? await sealing?.value
            try await handle.setDataAvailable(false, terminal: true)
            await self.releaseSealHold()
            try await graph.close()
            try await handle.close()
            await sourceHold.release()
        }
        closing = task
        do { try await task.value }
        catch { closing = nil; throw error }
    }

    private func releaseSealHold() async { await sealHold?.release(); sealHold = nil }

    /// Destruction is explicit and follows successful native detachment and ownership validation.
    package func discard() async throws {
        if let discarding { return try await discarding.value }
        let task = Task {
            try await self.close()
            try await self.removeOwnedFiles()
        }
        discarding = task
        do { try await task.value }
        catch { discarding = nil; throw error }
    }

    private func removeOwnedFiles() async throws {
        let directory = directory, descriptor = descriptor, ownership = ownership, storeOwnership = storeOwnership, activationID = activationID
        guard try WorkspaceDirectoryIdentity(directory) == ownership,
              try WorkspaceFileIdentity(directory.appendingPathComponent(descriptor.storePath)) == storeOwnership,
              try WorkspaceFiles.activation(directory) == activationID else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        if cleanupHandle == nil {
            cleanupHandle = try await registry.open(.init(location: .sqlite(directory.appendingPathComponent(descriptor.storePath)),
                exclusiveGraphID: descriptor.graphID.rawValue, workspaceID: id, workspaceSessionID: UUID()), schema: schema)
        }
        try await cleanupHandle!.discardWorkspace {
            guard try WorkspaceFiles.activation(directory) == activationID else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            try WorkspaceFiles.remove(directory, descriptor: descriptor, ownership: ownership, storeOwnership: storeOwnership)
        }
    }

    deinit {
        guard closing == nil else { return }
        let graph = graph, handle = handle, hold = sourceHold, sealHold = sealHold
        Task {
            do {
                try await handle.setDataAvailable(false, terminal: true)
                await sealHold?.release()
                try await graph.close(); try await handle.close()
                await hold.release()
            } catch { /* Retain native registry claims and working files on failed detachment. */ }
        }
    }
}

extension GraphContextManager {
    /// Reacquire source holds and prove provenance/history before any editable working access.
    package func openMigrationWorkspace(for id: GraphID, at directory: URL,
                                       limits: GraphMigrationWorkspaceLimits = .init()) async throws -> GraphMigrationWorkspace {
        try limits.validate()
        guard let workspaceAdapter = adapter.workspace, let location = locations[id] else { throw GraphMigrationWorkspaceError.unavailable }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = try WorkspaceFiles.read(directory)
        guard descriptor.graphID == id, descriptor.schema == schema.identifier else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        let retained = try await openGraph(id: id, at: location.url)
        var cloud: StoreReservation?, writes: StoreReservation?, maintenance: StoreReservation?, sealedWrites: StoreReservation?
        var working: StoreHandle?
        do {
            guard let entry = entries[id] else { throw GraphStoreError.closed }
            let owner = try await entry.opening.value
            cloud = try await reserveCloudPause(for: id)
            writes = try await owner.suspendLocalWrites()
            guard try await owner.participantAccess() == nil else { throw GraphMigrationWorkspaceError.participantUnsupported }
            guard try WorkspaceFileIdentity(location.url) == descriptor.sourceFile else { throw GraphMigrationWorkspaceError.staleSource }
            try await owner.validateMigrationSource(descriptor.source)
            let url = directory.appendingPathComponent(descriptor.storePath)
            guard try WorkspaceFileIdentity(url) == descriptor.workingFile else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            let sessionID = UUID()
            let handle = try await registry.open(.init(location: .sqlite(url), exclusiveGraphID: id.rawValue,
                workspaceID: descriptor.id, workspaceSessionID: sessionID), schema: schema)
            working = handle
            maintenance = try await handle.reserveMaintenance()
            let adapter = adapter
            let sealed = try await handle.workspaceTransaction(reservation: maintenance!) { context in
                try adapter.initialize(context, id, false)
                let result = try workspaceAdapter.inspect(context, descriptor, limits)
                guard !context.hasChanges else { throw GraphMigrationWorkspaceError.invalidWorkspace }
                return result
            }
            if sealed != nil { sealedWrites = try await handle.suspendWrites() }
            let ownership = try WorkspaceDirectoryIdentity(directory), storeOwnership = try WorkspaceFileIdentity(url)
            guard storeOwnership == descriptor.workingFile else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            _ = try WorkspaceFiles.activation(directory)
            try Data(sessionID.uuidString.utf8).write(to: directory.appendingPathComponent("activation"), options: .atomic)
            await maintenance?.release(); maintenance = nil
            try Task.checkCancellation()
            let graph = GraphStore.attached(id: id, handle: try await handle.newLease(), adapter: adapter.graph)
            let heldCloud = cloud!, heldWrites = writes!
            let hold = StoreReservation(id: descriptor.id) {
                await heldWrites.release(); await heldCloud.release(); try? await retained.close()
            }
            return GraphMigrationWorkspace(graph: graph, handle: handle, descriptor: descriptor, directory: directory,
                sourceHold: hold, ownership: ownership, storeOwnership: storeOwnership, adapter: workspaceAdapter,
                registry: registry, schema: schema, activationID: sessionID, sealed: sealed, sealHold: sealedWrites)
        } catch {
            let original = error
            await maintenance?.release(); await sealedWrites?.release()
            var cleanup: (any Error)?
            if case StoreRuntimeError.shutdownFailed = original { cleanup = original }
            if let working { do { try await working.close() } catch { cleanup = error } }
            await writes?.release(); await cloud?.release()
            do { try await retained.close() } catch { if cleanup == nil { cleanup = error } }
            if let cleanup { throw GraphMigrationWorkspaceCleanupFailure(directory: directory, preparationFailure: original, cleanupFailure: cleanup) }
            throw original
        }
    }

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
            let sourceFile = try WorkspaceFileIdentity(location.url)
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
            let sessionID = UUID()
            try Data(sessionID.uuidString.utf8).write(to: staging.appendingPathComponent("activation"), options: .withoutOverwriting)
            let configuration = StoreConfiguration(location: .sqlite(store), exclusiveGraphID: id.rawValue, workspaceID: workspaceID, workspaceSessionID: sessionID)
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
            let descriptor = GraphMigrationWorkspaceDescriptor(format: 2, id: workspaceID, graphID: id,
                schema: schema.identifier, storePath: "Graph.sqlite", source: source, baseline: baseline,
                sourceFile: sourceFile, workingFile: try WorkspaceFileIdentity(store))
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
                exclusiveGraphID: id.rawValue, workspaceID: workspaceID, workspaceSessionID: sessionID), schema: schema)
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
                storeOwnership: storeOwnership, adapter: adapter.workspace, registry: registry, schema: schema, activationID: sessionID)
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

package struct WorkspaceFileIdentity: Codable, Sendable, Equatable {
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

enum WorkspaceFiles {
    static let descriptorLimit = 256 * 1024
    static func activation(_ directory: URL) throws -> UUID {
        let url = directory.appendingPathComponent("activation")
        _ = try WorkspaceFileIdentity(url)
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue == 36,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8), let id = UUID(uuidString: text), id.uuidString == text else {
            throw GraphMigrationWorkspaceError.invalidWorkspace
        }
        return id
    }
    static func read(_ directory: URL) throws -> GraphMigrationWorkspaceDescriptor {
        _ = try WorkspaceDirectoryIdentity(directory)
        _ = try activation(directory)
        func data(_ name: String, maximum: Int) throws -> Data {
            let url = directory.appendingPathComponent(name)
            _ = try WorkspaceFileIdentity(url)
            guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                  size.intValue <= maximum else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            return try Data(contentsOf: url)
        }
        let descriptor: GraphMigrationWorkspaceDescriptor
        do { descriptor = try JSONDecoder().decode(GraphMigrationWorkspaceDescriptor.self, from: data("workspace.json", maximum: descriptorLimit)) }
        catch { throw GraphMigrationWorkspaceError.invalidWorkspace }
        guard descriptor.format == 2, descriptor.storePath == "Graph.sqlite",
              descriptor.sourceFile != descriptor.workingFile, descriptor.baseline.transaction.map({ $0 > 0 }) == true,
              !descriptor.source.storeID.isEmpty, !descriptor.baseline.storeID.isEmpty,
              try data("owner", maximum: 36) == Data(descriptor.id.uuidString.utf8) else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        _ = try GraphMigrationHistory.token(descriptor.source.token)
        _ = try GraphMigrationHistory.token(descriptor.baseline.token)
        return descriptor
    }
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
