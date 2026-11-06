import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

extension GraphReadScope {
    public func file(_ id: GraphNodeID) throws -> GraphFile? {
        guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
        return try withContext { context, adapter in
            _ = try ManagedGraphFile.root(in: context)
            guard let record = try adapter.fetch(context, graphID, id), record.endpoints == .file else { return nil }
            return try ManagedGraphFile.fetch(context, id: id).metadata(id: id)
        }
    }

    /// Enumerates fixed metadata without opening the content files.
    public func files() throws -> [GraphFile] {
        try withContext { context, _ in
            _ = try ManagedGraphFile.root(in: context)
            return try ManagedGraphFile.list(context, graphID: graphID)
        }
    }
}

extension GraphStore {
    public func file(_ id: GraphNodeID) async throws -> GraphFile? {
        try await read { try $0.file(id) }
    }

    public func files() async throws -> [GraphFile] {
        try await read { try $0.files() }
    }

    /// The graph owns its copy independently of the source URL.
    public func importFile(from source: URL, name: String? = nil, contentType: String = "public.data") async throws -> GraphFile {
        try await saveFile(makeNodeID(), from: source, name: name ?? source.lastPathComponent,
                           contentType: contentType, expectedRevision: nil)
    }

    /// Changes the current revision while preserving the node identity and its graph edges.
    public func replaceFile(_ file: GraphFile, from source: URL, name: String? = nil,
                            contentType: String? = nil) async throws -> GraphFile {
        try await saveFile(file.id, from: source, name: name ?? file.name,
                           contentType: contentType ?? file.contentType, expectedRevision: file.revision)
    }

    package func saveFile(_ fileID: GraphNodeID, from source: URL, name: String, contentType: String,
                          expectedRevision: UUID?, afterPublishing: @escaping @Sendable () throws -> Void = {}) async throws -> GraphFile {
        guard fileID.graphID == id else { throw GraphStoreError.foreignGraph }
        return try await transaction { scope in
            try scope.withContext { context, _ in
                let root = try ManagedGraphFile.root(in: context)
                let check = StoreNativeContext.cancellationCheck(in: context)
                let session = try GraphTypedStoreAdapter.Session(context, fileID.graphID, database: true)
                try session.requireWriteAccess()
                let previous: ManagedGraphFile?
                if let expectedRevision {
                    guard let file = try session.node(fileID)?.node as? ManagedGraphFile else { throw GraphStoreError.missingNode }
                    guard try file.metadata(id: fileID).revision == expectedRevision else { throw GraphFileError.conflict }
                    previous = file
                } else { previous = nil }

                let (file, stage) = try GraphFileDisk.prepare(from: source, in: root, id: fileID, name: name,
                                                             contentType: contentType, check: check)
                defer { try? FileManager.default.removeItem(at: stage) }
                try check()
                try GraphAttachmentIO.publishExclusive(stage, at: GraphFileDisk.url(for: file, in: root))
                try afterPublishing()
                if let previous {
                    previous.apply(file)
                    GraphMutationMetadata.touch(context, Entity(managedNode: previous), id: fileID)
                } else {
                    try session.insert(GraphRecord(id: fileID, type: GraphFile.nodeType, endpoints: .file), file: file)
                }
                return file
            }
        }
    }

    /// The URL is read-only and valid for the duration of the synchronous accessor.
    /// Export or copy within the accessor when the caller needs an independently owned file.
    public func withFileURL<Value: Sendable>(_ fileID: GraphNodeID,
        _ body: @escaping @Sendable (URL) throws -> Value) async throws -> Value {
        for attempt in 0...1 {
            let result: Result<Value, any Error>
            do {
                result = try await read { scope in
                    guard let file = try scope.file(fileID) else { throw GraphStoreError.missingNode }
                    return try scope.withContext { context, _ in
                        let root = try ManagedGraphFile.root(in: context)
                        let url = GraphFileDisk.url(for: file, in: root)
                        do {
                            try GraphFileDisk.validateRoot(root)
                            return try GraphFileDisk.coordinate(url, writing: false) { coordinated in
                                try GraphFileDisk.requireRegular(coordinated, count: file.byteCount)
                                return Result { try body(coordinated) }
                            }
                        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                            throw GraphFileError.missingContent
                        }
                    }
                }
            } catch GraphFileError.missingContent where attempt == 0 {
                // The pinned database snapshot can precede concurrent reclamation.
                // Only retry acquisition. The accessor runs after content is verified.
                continue
            }
            return try result.get()
        }
        throw GraphFileError.missingContent
    }

    public func deleteFile(_ fileID: GraphNodeID) async throws {
        try await transaction { scope in
            guard try scope.file(fileID) != nil else { throw GraphStoreError.missingNode }
            try scope.delete(fileID)
        }
    }

    /// Removes retired revisions and interrupted preparations under the store writer grant.
    @discardableResult
    public func reclaimFiles() async throws -> Int {
        try await transaction { scope in
            try scope.withContext { context, _ in
                let root = try ManagedGraphFile.root(in: context)
                guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
                try GraphFileDisk.ensureRoot(root)
                let retained = Set(try ManagedGraphFile.list(context, graphID: scope.graphID).map(\.revision))
                let check = StoreNativeContext.cancellationCheck(in: context)
                var removed = 0
                for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    try check()
                    let name = url.pathExtension == "partial" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                    guard let revision = UUID(uuidString: name), revision.uuidString == name, !retained.contains(revision) else { continue }
                    try GraphFileDisk.coordinate(url, writing: true) { coordinated in
                        let info = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw GraphFileError.corruptContent }
                        try FileManager.default.removeItem(at: coordinated)
                    }
                    removed += 1
                }
                return removed
            }
        }
    }
}

@available(iOS 17, macOS 14, *)
extension GraphContext {
    /// Migrates an ordinary, closed local S04 store into a new directory and returns its SQLite URL.
    /// The caller stops all owners of the source for the duration of the copy.
    public static func migrateClosedS04Store(from source: URL, into destination: URL) async throws -> URL {
        do {
            return try await ManagedGraphFile.publishStore(into: destination) { staged in
                try await SQLiteStoreCoordination.withStoppedSource(source) { source, check in
                    let old = GraphNativePropertyStorage.makeModel(), new = ManagedGraphFile.makeModel()
                    GraphValueTransformer.register()
                    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: source,
                        options: [NSReadOnlyPersistentStoreOption: true])
                    guard old.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                          let text = metadata[StoreNativeContext.historySyncGraphKey] as? String, let rawID = UUID(uuidString: text),
                          metadata[StoreNativeContext.workspaceKey] == nil else { throw GraphFileError.unavailable }
                    let sourceCoordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
                    let sourceStore = try sourceCoordinator.addPersistentStore(ofType: NSSQLiteStoreType,
                        configurationName: nil, at: source, options: [NSReadOnlyPersistentStoreOption: true])
                    let sourceContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                    sourceContext.persistentStoreCoordinator = sourceCoordinator
                    try sourceContext.performAndWait {
                        let root = try GraphTypedStoreAdapter.controlRoot(sourceContext, id: GraphID(rawValue: rawID))
                        guard root[dynamicMember: GraphCloudAccountNative.key] == nil else { throw GraphFileError.localOnly }
                    }
                    try sourceCoordinator.remove(sourceStore)
                    let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: new)
                    let migration = NSMigrationManager(sourceModel: old, destinationModel: new)
                    migration.usesStoreSpecificMigrationManager = false
                    try check()
                    try migration.migrateStore(from: source, sourceType: NSSQLiteStoreType,
                        options: [NSReadOnlyPersistentStoreOption: true], with: mapping, toDestinationURL: staged,
                        destinationType: NSSQLiteStoreType, destinationOptions: nil)
                    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: new)
                    let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: staged)
                    var migrated = coordinator.metadata(for: store)
                    migrated[StoreNativeContext.historySyncGraphKey] = text
                    coordinator.setMetadata(migrated, for: store)
                    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                    context.persistentStoreCoordinator = coordinator
                    try context.performAndWait {
                        let graphID = GraphID(rawValue: rawID)
                        try GraphCoordinatorFactory.adapter.initialize(context, graphID, false)
                        _ = try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: graphID)
                    }
                    try coordinator.remove(store)
                    try check()
                }
            }
        } catch { throw GraphStore.translate(error) }
    }
}

extension GraphStore {
    /// Creates an independent local SQLite copy together with every referenced file.
    /// Open the returned URL with a local-files context to restore it.
    public func copyLocalFileGraph(into destination: URL) async throws -> URL {
        let snapshot = try await handle.snapshot()
        guard snapshot.schemaIdentifier == GraphFileDisk.schemaIdentifier else { throw GraphFileError.unavailable }
        let graphID = id
        let reservation = try await handle.reserveMaintenance()
        do {
            let url = try await ManagedGraphFile.publishStore(into: destination) { staged in
                try await self.handle.copyStore(to: staged, reservation: reservation) { context, target, check in
                    try ManagedGraphFile.copyFiles(context, graphID: graphID, to: target, check: check)
                }
            }
            await reservation.release()
            return url
        } catch {
            await reservation.release()
            throw error
        }
    }
}
