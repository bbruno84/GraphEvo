import CloudKit
import CoreData
import Foundation
import GraphEvoStore
import GraphEvoRuntime
import GraphEvoModel

@objc(ManagedGraphFile)
final class ManagedGraphFile: ManagedEntity {
    static let entityName = "ManagedGraphFile"
    @NSManaged private var geFileName: String?
    @NSManaged private var geFileContentType: String?
    @NSManaged private var geFileByteCount: Int64
    @NSManaged private var geFileDigest: String?
    @NSManaged private var geFileRevision: UUID?

    static func makeModel() -> NSManagedObjectModel {
        let model = GraphNativePropertyStorage.makeModel()
        let base = model.entitiesByName[ModelIdentifier.entityName]!
        let file = NSEntityDescription()
        file.name = entityName
        file.managedObjectClassName = NSStringFromClass(ManagedGraphFile.self)
        let fields: [(String, NSAttributeType)] = [
            ("geFileName", .stringAttributeType), ("geFileContentType", .stringAttributeType),
            ("geFileByteCount", .integer64AttributeType), ("geFileDigest", .stringAttributeType),
            ("geFileRevision", .UUIDAttributeType)
        ]
        file.properties = fields.map { name, type in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            return attribute
        }
        base.subentities = [file]
        if model.entitiesByName[entityName] == nil { model.entities.append(file) }
        model.versionIdentifiers = [GraphFileDisk.schemaIdentifier]
        return model
    }

    func metadata(id: GraphNodeID) throws -> GraphFile {
        guard let geFileName, let geFileContentType, let geFileDigest, let geFileRevision else {
            throw GraphFileError.invalidMetadata
        }
        return try GraphFile(id: id, name: geFileName, contentType: geFileContentType, byteCount: geFileByteCount,
                             sha256: geFileDigest, revision: geFileRevision)
    }

    func apply(_ file: GraphFile) {
        geFileName = file.name
        geFileContentType = file.contentType
        geFileByteCount = file.byteCount
        geFileDigest = file.sha256
        geFileRevision = file.revision
    }
}

extension ManagedGraphFile {
    static func root(in context: NSManagedObjectContext, relocatingTo destination: URL? = nil) throws -> URL {
        guard let coordinator = context.persistentStoreCoordinator,
              (coordinator.managedObjectModel.versionIdentifiers == [AnyHashable(GraphFileDisk.schemaIdentifier)] ||
               coordinator.managedObjectModel.versionIdentifiers == [AnyHashable(GraphNativeAttachmentStorage.fileIdentifier)]),
              coordinator.persistentStores.count == 1, let store = coordinator.persistentStores.first,
              store.type == NSSQLiteStoreType, let url = store.url else { throw GraphFileError.unavailable }
        guard let rawID = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String,
              let storeID = UUID(uuidString: rawID) else { throw GraphStoreError.corruptIdentity }
        return GraphFileDisk.root(for: destination ?? url, storeID: storeID)
    }

    static func fetch(_ context: NSManagedObjectContext, id: GraphNodeID) throws -> ManagedGraphFile {
        let request = NSFetchRequest<ManagedGraphFile>(entityName: entityName)
        request.predicate = NSPredicate(format: "ge2GraphID == %@ AND ge2NodeID == %@",
            id.graphID.rawValue.uuidString, id.rawValue.uuidString)
        let files = try context.fetch(request)
        guard files.count == 1, let file = files.first else { throw GraphStoreError.corruptIdentity }
        return file
    }

    static func list(_ context: NSManagedObjectContext, graphID: GraphID) throws -> [GraphFile] {
        let request = NSFetchRequest<ManagedGraphFile>(entityName: entityName)
        request.predicate = NSPredicate(format: "ge2GraphID == %@", graphID.rawValue.uuidString)
        return try context.fetch(request).map { file in
            guard let text = file.value(forKey: "ge2NodeID") as? String, let uuid = UUID(uuidString: text) else {
                throw GraphStoreError.corruptIdentity
            }
            return try file.metadata(id: GraphNodeID(graphID: graphID, rawValue: uuid))
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    static func copyFiles(_ context: NSManagedObjectContext, graphID: GraphID, to store: URL,
                          check: CoordinatedFiles.CancellationCheck) throws {
        let source = try root(in: context)
        let files = try list(context, graphID: graphID)
        guard !files.isEmpty else { return }
        let destination = try root(in: context, relocatingTo: store)
        try GraphFileDisk.validateRoot(source)
        try GraphFileDisk.ensureRoot(destination)
        for file in files {
            try check()
            let input = GraphFileDisk.url(for: file, in: source)
            try GraphFileDisk.requireRegular(input, count: file.byteCount)
            let output = GraphFileDisk.url(for: file, in: destination)
            try FileManager.default.copyItem(at: input, to: output)
            try GraphFileDisk.verify(output, file: file, check: check)
        }
    }

    static func publishStore(into destination: URL, prepare: @Sendable (URL) async throws -> Void) async throws -> URL {
        guard destination.isFileURL, destination.query == nil, destination.fragment == nil else { throw GraphFileError.invalidMetadata }
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try AppGroupStoreLocation.rejectUncoordinated(target)
        let stage = parent.appendingPathComponent(".GraphEvoFileCopy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let staged = stage.appendingPathComponent("Graph.sqlite")
        try await prepare(staged)
        try await CoordinatedFiles.run([.write(target)]) { try GraphAttachmentIO.publishExclusive(stage, at: target) }
        return target.appendingPathComponent("Graph.sqlite")
    }
}

extension ManagedGraphFile {
    static func installRemote(_ remote: GraphCloudDecodedNode, session: GraphTypedStoreAdapter.Session) throws {
        let record = remote.record
        guard let metadata = record.file, metadata.id == record.id else { throw GraphCloudNodeError.invalidRecord }
        let root = try root(in: session.context)
        try GraphFileDisk.ensureRoot(root)
        let target = GraphFileDisk.url(for: metadata, in: root)
        let check = StoreNativeContext.cancellationCheck(in: session.context)
        if FileManager.default.fileExists(atPath: target.path) {
            try GraphFileDisk.verify(target, file: metadata, check: check)
        } else {
            guard let source = remote.fileSource else { throw GraphFileError.missingContent }
            let (copied, stage) = try GraphFileDisk.prepare(from: source, in: root, id: record.id,
                name: metadata.name, contentType: metadata.contentType, check: check)
            defer { try? FileManager.default.removeItem(at: stage) }
            guard copied.byteCount == metadata.byteCount, copied.sha256 == metadata.sha256 else {
                throw GraphFileError.corruptContent
            }
            try check()
            try GraphAttachmentIO.publishExclusive(stage, at: target)
        }
        if let existing = try session.node(record.id) {
            guard let file = existing.node as? ManagedGraphFile, existing.type == record.type else {
                throw GraphCloudNodeError.invalidRecord
            }
            file.apply(metadata)
            _ = try session.patch(GraphRecordPatch(id: record.id,
                addingTags: record.tags.subtracting(existing.tags), removingTags: Set(existing.tags).subtracting(record.tags),
                addingGroups: record.groups.subtracting(existing.groups), removingGroups: Set(existing.groups).subtracting(record.groups)))
        } else {
            try session.insert(record, file: metadata)
        }
    }
}
