import CloudKit
import CryptoKit
import Darwin
import Foundation
import GraphEvoModel

/// A durable, route-bound reference to an owned temporary CloudKit asset.
package struct GraphCloudAssetReference: Codable, Equatable, Sendable {
    package enum Role: String, Codable, Sendable { case outgoing, incoming }

    package let isFile: Bool?
    package let format: Int
    package let role: Role
    package let namespace: UUID
    package let file: UUID
    package let identity: GraphCloudSessionIdentity
    package let binding: GraphCloudBinding
    package let recordName: String
    package let byteCount: Int
    package let sha256: String
    package let storeID: String?
    package let epoch: UUID?

    package init(role: Role, namespace: UUID, file: UUID, identity: GraphCloudSessionIdentity,
                 binding: GraphCloudBinding, recordName: String, byteCount: Int, sha256: String,
                 storeID: String? = nil, epoch: UUID? = nil, isFile: Bool = false) {
        self.isFile = isFile ? true : nil
        self.format = 2; self.role = role; self.namespace = namespace; self.file = file
        self.identity = identity; self.binding = binding; self.recordName = recordName
        self.byteCount = byteCount; self.sha256 = sha256; self.storeID = storeID; self.epoch = epoch
    }

    package func validate(role expectedRole: Role, identity expectedIdentity: GraphCloudSessionIdentity,
                          binding expectedBinding: GraphCloudBinding, recordName expectedName: String,
                          storeID expectedStoreID: String? = nil, epoch expectedEpoch: UUID? = nil) throws {
        guard format == 2, role == expectedRole, identity == expectedIdentity, binding == expectedBinding,
              recordName == expectedName, !recordName.isEmpty,
              byteCount >= 0, UInt64(byteCount) <= (isFile == true ? GraphCloudAsset.maximumNativeByteCount : UInt64(Int(GraphCloudAsset.maximumNativeByteCount))),
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (role == .outgoing) == (storeID != nil && epoch != nil),
              storeID == expectedStoreID, epoch == expectedEpoch else { throw GraphCloudError.invalidState }
    }
}

/// Files are temporary transport state. The caller supplies the current owned root, not a persisted URL.
package struct GraphCloudAssetSpool: Sendable {
    package let root: URL

    package init(root: URL) throws {
        guard root.isFileURL, root.query == nil, root.fragment == nil,
              (root.lastPathComponent == "GraphEvoCloudAssets" ||
               (root.deletingLastPathComponent().lastPathComponent == "GraphEvoCloudAssets" &&
                root.lastPathComponent.utf8.count == 64 &&
                root.lastPathComponent.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }))) else {
            throw GraphCloudError.invalidConfiguration
        }
        self.root = root.standardizedFileURL
    }

    package static func outgoingRoot(storeURL: URL, storeID: String) -> URL {
        let name = SHA256.hash(data: Data(storeID.utf8)).map { String(format: "%02x", $0) }.joined()
        return storeURL.deletingLastPathComponent().appendingPathComponent("GraphEvoCloudAssets", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    package func stage(_ data: Data, role: GraphCloudAssetReference.Role, namespace: UUID,
                       identity: GraphCloudSessionIdentity, binding: GraphCloudBinding,
                       recordName: String, storeID: String? = nil, epoch: UUID? = nil) async throws -> GraphCloudAssetReference {
        try await GraphAttachmentIO.perform {
            try self.stageBlocking(data, role: role, namespace: namespace, identity: identity,
                                   binding: binding, recordName: recordName, storeID: storeID, epoch: epoch)
        }
    }

    /// Session event publication is serial; this bounded write completes before a checkpoint is stored.
    package func stageBlocking(_ data: Data, role: GraphCloudAssetReference.Role, namespace: UUID,
                               identity: GraphCloudSessionIdentity, binding: GraphCloudBinding,
                               recordName: String, storeID: String? = nil, epoch: UUID? = nil,
                               check: () throws -> Void = { try Task.checkCancellation() }) throws -> GraphCloudAssetReference {
        guard data.count <= Int(GraphCloudAsset.maximumNativeByteCount) else { throw GraphCloudError.inboxLimit }
        let file = UUID()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = GraphCloudAssetReference(role: role, namespace: namespace, file: file,
            identity: identity, binding: binding, recordName: recordName, byteCount: data.count,
            sha256: digest, storeID: storeID, epoch: epoch)
        try reference.validate(role: role, identity: identity, binding: binding, recordName: recordName,
                               storeID: storeID, epoch: epoch)
        try check()
        try Self.ensureRoot(root)
        let directory = root.appendingPathComponent(namespace.uuidString, isDirectory: true)
        try Self.ensurePrivateDirectory(directory)
        let target = directory.appendingPathComponent(file.uuidString)
        let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw GraphCloudError.persistence }
        defer { Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    try check()
                    let count = Darwin.write(descriptor, base.advanced(by: offset), min(raw.count - offset, 256 * 1024))
                    guard count > 0 else { throw GraphCloudError.persistence }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw GraphCloudError.persistence }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return reference
    }

    package func stageFileBlocking(from source: URL, role: GraphCloudAssetReference.Role, namespace: UUID,
        identity: GraphCloudSessionIdentity, binding: GraphCloudBinding, recordName: String,
        storeID: String? = nil, epoch: UUID? = nil, isFile: Bool = true, check: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> GraphCloudAssetReference {
        try Self.ensureRoot(root)
        let directory = root.appendingPathComponent(namespace.uuidString, isDirectory: true)
        try Self.ensurePrivateDirectory(directory)
        let id = GraphNodeID(graphID: binding.graphID)
        let (metadata, temporary) = try GraphFileDisk.prepare(from: source, in: directory, id: id,
            name: "asset", contentType: "public.data", maximumBytes: Int64(GraphCloudAsset.maximumNativeByteCount), check: check)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reference = GraphCloudAssetReference(role: role, namespace: namespace, file: metadata.revision,
            identity: identity, binding: binding, recordName: recordName, byteCount: Int(metadata.byteCount),
            sha256: metadata.sha256, storeID: storeID, epoch: epoch, isFile: isFile)
        try reference.validate(role: role, identity: identity, binding: binding, recordName: recordName,
                               storeID: storeID, epoch: epoch)
        try check()
        try GraphAttachmentIO.publishExclusive(temporary, at: directory.appendingPathComponent(reference.file.uuidString))
        return reference
    }

    package func fileURL(_ reference: GraphCloudAssetReference, role: GraphCloudAssetReference.Role,
        identity: GraphCloudSessionIdentity, binding: GraphCloudBinding, recordName: String,
        storeID: String? = nil, epoch: UUID? = nil
    ) async throws -> URL {
        try await GraphAttachmentIO.perform {
            try self.fileURLBlocking(reference, role: role, identity: identity, binding: binding,
                recordName: recordName, storeID: storeID, epoch: epoch)
        }
    }

    package func fileURLBlocking(_ reference: GraphCloudAssetReference, role: GraphCloudAssetReference.Role,
        identity: GraphCloudSessionIdentity, binding: GraphCloudBinding, recordName: String,
        storeID: String? = nil, epoch: UUID? = nil
    ) throws -> URL {
        try presenceBlocking(reference, role: role, identity: identity, binding: binding, recordName: recordName,
                             storeID: storeID, epoch: epoch)
        let url = root.appendingPathComponent(reference.namespace.uuidString).appendingPathComponent(reference.file.uuidString)
        let metadata = try GraphFile(id: GraphNodeID(graphID: binding.graphID), name: "asset",
            contentType: "public.data", byteCount: Int64(reference.byteCount), sha256: reference.sha256, revision: reference.file)
        try GraphFileDisk.verify(url, file: metadata, check: { try Task.checkCancellation() })
        return url
    }

    package func read(_ reference: GraphCloudAssetReference, role: GraphCloudAssetReference.Role,
                      identity: GraphCloudSessionIdentity, binding: GraphCloudBinding,
                      recordName: String, storeID: String? = nil, epoch: UUID? = nil) async throws -> Data {
        try reference.validate(role: role, identity: identity, binding: binding, recordName: recordName,
                               storeID: storeID, epoch: epoch)
        guard reference.isFile != true else { throw GraphCloudError.unsupportedAsset }
        return try await GraphAttachmentIO.perform {
            if self.root.lastPathComponent != "GraphEvoCloudAssets" {
                try Self.checkPrivateDirectory(self.root.deletingLastPathComponent())
            }
            try Self.checkPrivateDirectory(self.root)
            try Self.checkMarker(self.root)
            let directory = self.root.appendingPathComponent(reference.namespace.uuidString, isDirectory: true)
            try Self.checkPrivateDirectory(directory)
            let path = directory.appendingPathComponent(reference.file.uuidString)
            let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GraphCloudError.invalidState }
            defer { Darwin.close(descriptor) }
            var statValue = stat()
            guard fstat(descriptor, &statValue) == 0, (statValue.st_mode & S_IFMT) == S_IFREG,
                  statValue.st_nlink == 1, statValue.st_uid == getuid(), statValue.st_mode & 0o077 == 0,
                  statValue.st_size == reference.byteCount else { throw GraphCloudError.invalidState }
            var data = Data()
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            while true {
                try Task.checkCancellation()
                let remaining = reference.byteCount - data.count
                guard let chunk = try handle.read(upToCount: min(remaining + 1, 256 * 1024)), !chunk.isEmpty else { break }
                guard chunk.count <= remaining else { throw GraphCloudError.invalidState }
                data.append(chunk)
            }
            guard data.count == reference.byteCount,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.sha256 else {
                throw GraphCloudError.invalidState
            }
            return data
        }
    }

    /// Startup checks only ownership and length. Content is hashed when actually consumed.
    package func presence(_ reference: GraphCloudAssetReference, role: GraphCloudAssetReference.Role,
                          identity: GraphCloudSessionIdentity, binding: GraphCloudBinding,
                          recordName: String, storeID: String? = nil, epoch: UUID? = nil) async throws {
        try await GraphAttachmentIO.perform {
            try presenceBlocking(reference, role: role, identity: identity, binding: binding,
                                 recordName: recordName, storeID: storeID, epoch: epoch)
        }
    }

    private func presenceBlocking(_ reference: GraphCloudAssetReference, role: GraphCloudAssetReference.Role,
                                  identity: GraphCloudSessionIdentity, binding: GraphCloudBinding,
                                  recordName: String, storeID: String?, epoch: UUID?) throws {
        try reference.validate(role: role, identity: identity, binding: binding, recordName: recordName,
                               storeID: storeID, epoch: epoch)
        if root.lastPathComponent != "GraphEvoCloudAssets" {
            try Self.checkPrivateDirectory(root.deletingLastPathComponent())
        }
        try Self.checkPrivateDirectory(root)
        try Self.checkMarker(root)
        let directory = root.appendingPathComponent(reference.namespace.uuidString, isDirectory: true)
        try Self.checkPrivateDirectory(directory)
        let path = directory.appendingPathComponent(reference.file.uuidString)
        var value = stat()
        guard lstat(path.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
              value.st_size == reference.byteCount else { throw GraphCloudError.invalidState }
    }

    package func freeze(_ prepared: GraphCloudPreparedOutgoing, identity: GraphCloudSessionIdentity,
                        stagingNamespace: UUID? = nil,
                        check: @escaping @Sendable () throws -> Void) async throws -> GraphCloudOutgoingBatch {
        try await GraphAttachmentIO.perform {
            try freezeBlocking(prepared, identity: identity, stagingNamespace: stagingNamespace) {
                try Task.checkCancellation(); try check()
            }
        }
    }

    /// Without a staging namespace the caller must retain the store writer grant through save.
    func freezeBlocking(_ prepared: GraphCloudPreparedOutgoing, identity: GraphCloudSessionIdentity,
                        stagingNamespace: UUID? = nil, check: () throws -> Void) throws -> GraphCloudOutgoingBatch {
        let batch = prepared.batch
        let binding = GraphCloudBinding(zone: batch.zone, graphID: batch.graphID)
        if stagingNamespace == nil {
            try reconcileBlocking(retaining: prepared.previousAssets + batch.items.compactMap(\.assetReference), check: check)
        }
        var items: [GraphCloudOutgoingNode] = []
        var preparedBytes = 0
        var staged: [GraphCloudAssetReference] = []
        do {
            for item in batch.items {
                try check()
                guard let archive = item.recordArchive else {
                    guard item.assetReference == nil else { throw GraphCloudError.invalidState }
                    items.append(item); continue
                }
                let record = try GraphCloudRecordCodec.restore(archive)
                if let reference = item.assetReference {
                    try reference.validate(role: .outgoing, identity: identity, binding: binding,
                                           recordName: item.recordName, storeID: prepared.storeID, epoch: prepared.epoch)
                    try GraphCloudNodeCodec.validateReferenceArchive(record, reference: reference, binding: binding)
                    try presenceBlocking(reference, role: .outgoing, identity: identity, binding: binding,
                                       recordName: item.recordName, storeID: prepared.storeID, epoch: prepared.epoch)
                    items.append(item)
                } else if let source = prepared.fileSources[item.recordName] {
                    let reference = try stageFileBlocking(from: source, role: .outgoing, namespace: stagingNamespace ?? batch.id,
                        identity: identity, binding: binding, recordName: item.recordName,
                        storeID: prepared.storeID, epoch: prepared.epoch, check: check)
                    staged.append(reference)
                    try GraphCloudNodeCodec.validateReferenceArchive(record, reference: reference, binding: binding)
                    items.append(GraphCloudOutgoingNode(change: item.change, recordName: item.recordName,
                        recordArchive: archive, assetReference: reference))
                } else if record["asset"] != nil {
                    let data = try GraphCloudAsset.bytes(record["asset"])
                    guard preparedBytes == 0 || data.count <= 32 * 1024 * 1024 - preparedBytes else { throw GraphCloudError.inboxLimit }
                    preparedBytes += data.count
                    let reference = try stageBlocking(data, role: .outgoing, namespace: stagingNamespace ?? batch.id, identity: identity,
                                                    binding: binding, recordName: item.recordName,
                                                    storeID: prepared.storeID, epoch: prepared.epoch, check: check)
                    staged.append(reference)
                    record["asset"] = Data() as CKRecordValue
                    try GraphCloudNodeCodec.validateReferenceArchive(record, reference: reference, binding: binding)
                    let frozen = try GraphCloudRecordCodec.archive(record, scope: batch.zone.scope, portableAsset: true)
                    items.append(GraphCloudOutgoingNode(change: item.change, recordName: item.recordName,
                                                        recordArchive: frozen.recordArchive, assetReference: reference))
                } else { items.append(item) }
            }
        } catch {
            try? removeBlocking(staged, retaining: [])
            throw error
        }
        return GraphCloudOutgoingBatch(id: batch.id, graphID: batch.graphID, zone: batch.zone,
                                       items: items, assetRoot: root)
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let result = Darwin.mkdir(directory.path, S_IRUSR | S_IWUSR | S_IXUSR)
        guard result == 0 || errno == EEXIST else { throw GraphCloudError.persistence }
        try checkPrivateDirectory(directory)
    }

    private static func ensureRoot(_ root: URL) throws {
        let parent = root.deletingLastPathComponent()
        if root.lastPathComponent != "GraphEvoCloudAssets" { try ensurePrivateDirectory(parent) }
        var existing = stat()
        if lstat(root.path, &existing) == 0 {
            try checkPrivateDirectory(root)
            try checkMarker(root)
            return
        }
        guard errno == ENOENT else { throw GraphCloudError.invalidState }
        let temporary = parent.appendingPathComponent(".GraphEvoAssetRoot-" + UUID().uuidString, isDirectory: true)
        try ensurePrivateDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ensureMarker(temporary)
        do { try GraphAttachmentIO.publishExclusive(temporary, at: root) }
        catch GraphAttachmentError.destinationExists {
            try checkPrivateDirectory(root)
            try checkMarker(root)
        }
    }

    private static func checkPrivateDirectory(_ directory: URL) throws {
        var value = stat()
        guard lstat(directory.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { throw GraphCloudError.invalidState }
    }

    private static let markerText = Data("GraphEvoCloudAssets:1\n".utf8)

    private static func ensureMarker(_ directory: URL) throws {
        let marker = directory.appendingPathComponent("format-1")
        if FileManager.default.fileExists(atPath: marker.path) { try checkMarker(directory); return }
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard contents.isEmpty else { throw GraphCloudError.invalidState }
        let descriptor = Darwin.open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw GraphCloudError.persistence }
        defer { Darwin.close(descriptor) }
        try markerText.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  Darwin.write(descriptor, base, raw.count) == raw.count,
                  fsync(descriptor) == 0 else { throw GraphCloudError.persistence }
        }
    }

    private static func checkMarker(_ directory: URL) throws {
        let marker = directory.appendingPathComponent("format-1")
        let descriptor = Darwin.open(marker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GraphCloudError.invalidState }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
              value.st_size == markerText.count else {
            throw GraphCloudError.invalidState
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard try handle.readToEnd() == markerText else { throw GraphCloudError.invalidState }
    }

    /// Only this caller's owned root may be swept, after its complete durable reference set is known.
    package func reconcile(retaining references: [GraphCloudAssetReference]) async throws {
        try await GraphAttachmentIO.perform {
            try reconcileBlocking(retaining: references, check: { try Task.checkCancellation() })
        }
    }

    private func reconcileBlocking(retaining references: [GraphCloudAssetReference], check: () throws -> Void) throws {
        let retained = Set(references.map { $0.namespace.uuidString + "/" + $0.file.uuidString })
        guard FileManager.default.fileExists(atPath: root.path) else {
            guard references.isEmpty else { throw GraphCloudError.invalidState }
            return
        }
        try Self.checkPrivateDirectory(root)
        try Self.checkMarker(root)
        for namespace in try FileManager.default.contentsOfDirectory(atPath: root.path) where namespace != "format-1" {
            try check()
            guard let uuid = UUID(uuidString: namespace), uuid.uuidString == namespace else { continue }
            let directory = root.appendingPathComponent(namespace, isDirectory: true)
            try Self.checkPrivateDirectory(directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                try check()
                guard let file = UUID(uuidString: name), file.uuidString == name,
                      !retained.contains(namespace + "/" + name) else { continue }
                try Self.removeFile(directory.appendingPathComponent(name))
            }
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                guard Darwin.rmdir(directory.path) == 0 else { throw GraphCloudError.persistence }
            }
        }
    }

    package func remove(_ references: [GraphCloudAssetReference], retaining kept: [GraphCloudAssetReference]) async {
        _ = try? await GraphAttachmentIO.perform { try removeBlocking(references, retaining: kept) }
    }

    func removeBlocking(_ references: [GraphCloudAssetReference], retaining kept: [GraphCloudAssetReference]) throws {
        let retained = Set(kept.map { $0.namespace.uuidString + "/" + $0.file.uuidString })
        try Self.checkPrivateDirectory(root)
        try Self.checkMarker(root)
        for reference in references where !retained.contains(reference.namespace.uuidString + "/" + reference.file.uuidString) {
            let directory = root.appendingPathComponent(reference.namespace.uuidString, isDirectory: true)
            try Self.checkPrivateDirectory(directory)
            try Self.removeFile(directory.appendingPathComponent(reference.file.uuidString))
        }
    }

    /// Terminal purge holds the exact native store's exclusive deletion grant.
    package func removeOwnedRoot() throws {
        var value = stat()
        guard lstat(root.path, &value) == 0 else {
            if errno == ENOENT { return }
            throw GraphCloudError.invalidState
        }
        try Self.checkPrivateDirectory(root)
        // A prior purge may have removed the marker immediately before interruption.
        if try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty {
            guard rmdir(root.path) == 0 else { throw GraphCloudError.persistence }
            return
        }
        try Self.checkMarker(root)
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name != "format-1" {
            guard let id = UUID(uuidString: name), id.uuidString == name else { throw GraphCloudError.invalidState }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try Self.checkPrivateDirectory(directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let revision = name.hasSuffix(".partial") ? String(name.dropLast(8)) : name
                guard let id = UUID(uuidString: revision), id.uuidString == revision else { throw GraphCloudError.invalidState }
                try Self.removeFile(directory.appendingPathComponent(name))
            }
            guard rmdir(directory.path) == 0 else { throw GraphCloudError.persistence }
        }
        try Self.checkMarker(root)
        try Self.removeFile(root.appendingPathComponent("format-1"))
        guard rmdir(root.path) == 0 else { throw GraphCloudError.persistence }
    }

    /// Copy a frozen outgoing attempt alongside a native snapshot under the caller's maintenance reservation.
    package func copyOwnedRoot(to destination: URL) async throws {
        try await GraphAttachmentIO.perform {
            try copyOwnedRoot(to: destination, check: { try Task.checkCancellation() })
        }
    }

    package func copyOwnedRoot(to destination: URL, check: () throws -> Void) throws {
        try check()
        var value = stat()
        if lstat(self.root.path, &value) != 0 {
            guard errno == ENOENT else { throw GraphCloudError.invalidState }
            return
        }
        try Self.checkPrivateDirectory(self.root)
        try Self.checkMarker(self.root)
        for namespace in try FileManager.default.contentsOfDirectory(atPath: self.root.path) where namespace != "format-1" {
            guard let id = UUID(uuidString: namespace), id.uuidString == namespace else { throw GraphCloudError.invalidState }
            let directory = self.root.appendingPathComponent(namespace, isDirectory: true)
            try Self.checkPrivateDirectory(directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                try check()
                guard let id = UUID(uuidString: name), id.uuidString == name else { throw GraphCloudError.invalidState }
                let path = directory.appendingPathComponent(name)
                guard lstat(path.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
                      value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0 else {
                    throw GraphCloudError.invalidState
                }
            }
        }
        try Self.ensurePrivateDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".GraphEvoAssetCopy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: self.root, to: temporary)
        try Self.checkPrivateDirectory(temporary)
        try Self.checkMarker(temporary)
        try check()
        try GraphAttachmentIO.publishExclusive(temporary, at: destination)
    }

    private static func removeFile(_ path: URL) throws {
        var value = stat()
        guard lstat(path.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
              value.st_nlink == 1, value.st_uid == getuid(), value.st_mode & 0o077 == 0,
              Darwin.unlink(path.path) == 0 else { throw GraphCloudError.invalidState }
    }
}
