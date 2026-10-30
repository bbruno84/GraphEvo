import CryptoKit
import Foundation
import GraphEvoModel

package enum GraphDataMigrationError: Error, Equatable {
    case invalidDefinition, invalidArchive, budgetExceeded, sourceFormatMismatch
    case invalidTransformation, destinationMismatch, sourceChanged, reconciliationRequired, busy
}

/// Detached format metadata. Nil is undeclared, never an inferred legacy version.
package struct GraphDataMigrationRow: Sendable, Equatable {
    package let record: GraphRecord
    package var dataVersion: Int64? { record.dataVersion }
    package init(record: GraphRecord, dataVersion: Int64?) throws {
        guard dataVersion.map({ $0 >= 0 }) ?? true else { throw GraphDataMigrationError.sourceFormatMismatch }
        self.record = try GraphRecord(id: record.id, type: record.type, endpoints: record.endpoints,
            properties: record.properties, tags: record.tags, groups: record.groups,
            createdDate: record.createdDate, dataVersion: dataVersion)
    }
}

/// M2a: pure per-record data conversion, no structural edits, file lifecycle or external writes.
/// Package-only until all normal public read/write/query paths support format admission.
package struct GraphDataMigrationDefinition: Sendable {
    package let descriptor: GraphDataMigrationDescriptor
    package let transform: @Sendable (GraphRecord) throws -> GraphRecord
    package init(id: String, revision: Int, type: String, kind: GraphNodeKind,
                 sourceVersion: Int64?, targetVersion: Int64, records: [GraphNodeID],
                 maximumArtifactBytes: Int = 1_048_576,
                 transform: @escaping @Sendable (GraphRecord) throws -> GraphRecord) throws {
        guard !id.isEmpty, revision > 0, !type.isEmpty, !type.hasPrefix("__graphevo_v2."),
              type != GraphAttachmentPayload.graphType, targetVersion >= 0,
              sourceVersion.map({ $0 >= 0 && targetVersion > $0 }) ?? true,
              !records.isEmpty, records.count <= 128, Set(records).count == records.count,
              let graph = records.first?.graphID, records.allSatisfy({ $0.graphID == graph }),
              maximumArtifactBytes > 0 else { throw GraphDataMigrationError.invalidDefinition }
        descriptor = GraphDataMigrationDescriptor(id: id, revision: revision, type: type,
            kind: GraphDataMigrationRecord.kindName(kind), graph: graph.rawValue,
            nodes: records.map(\.rawValue).sorted { $0.uuidString < $1.uuidString },
            sourceVersion: sourceVersion, targetVersion: targetVersion, maximumArtifactBytes: maximumArtifactBytes)
        self.transform = transform
    }
}

package struct GraphDataMigrationDescriptor: Codable, Equatable, Sendable {
    package let id: String
    package let revision: Int
    package let type: String
    package let kind: String
    package let graph: UUID
    package let nodes: [UUID]
    package let sourceVersion: Int64?
    package let targetVersion: Int64
    package let maximumArtifactBytes: Int
    package var recordIDs: [GraphNodeID] { nodes.map { GraphNodeID(graphID: GraphID(rawValue: graph), rawValue: $0) } }
}

/// Private artifact encoding, not a new public GraphRecord serialization contract.
package struct GraphDataMigrationRecord: Codable, Sendable {
    let graph: UUID
    let node: UUID
    let type: String
    let kind: String
    let subjects: [UUID]
    let objects: [UUID]
    let values: [String: Data]
    let tags: [String]
    let groups: [String]
    let created: Date?
    let version: Int64?

    static func kindName(_ kind: GraphNodeKind) -> String {
        switch kind { case .entity: "entity"; case .relationship: "relationship"; case .action: "action" }
    }
    init(_ row: GraphDataMigrationRow) throws {
        let record = row.record
        graph = record.id.graphID.rawValue; node = record.id.rawValue; type = record.type
        kind = Self.kindName(record.endpoints.kind)
        switch record.endpoints {
        case .entity: subjects = []; objects = []
        case .relationship(let a, let b): subjects = a.map { [$0.rawValue] } ?? []; objects = b.map { [$0.rawValue] } ?? []
        case .action(let a, let b):
            subjects = a.map(\.rawValue).sorted { $0.uuidString < $1.uuidString }
            objects = b.map(\.rawValue).sorted { $0.uuidString < $1.uuidString }
        }
        values = try record.properties.mapValues { try GraphValueCodec.encode($0) }
        tags = record.tags.sorted(); groups = record.groups.sorted(); created = record.createdDate; version = row.dataVersion
    }
    func decoded() throws -> GraphDataMigrationRow {
        let graphID = GraphID(rawValue: graph)
        func ids(_ values: [UUID]) -> [GraphNodeID] { values.map { GraphNodeID(graphID: graphID, rawValue: $0) } }
        let endpoints: GraphEndpoints
        switch kind {
        case "entity":
            guard subjects.isEmpty, objects.isEmpty else { throw GraphDataMigrationError.invalidArchive }
            endpoints = .entity
        case "relationship":
            guard subjects.count <= 1, objects.count <= 1 else { throw GraphDataMigrationError.invalidArchive }
            endpoints = .relationship(subject: ids(subjects).first, object: ids(objects).first)
        case "action":
            guard Set(subjects).count == subjects.count, Set(objects).count == objects.count else { throw GraphDataMigrationError.invalidArchive }
            endpoints = .action(subjects: Set(ids(subjects)), objects: Set(ids(objects)))
        default: throw GraphDataMigrationError.invalidArchive
        }
        guard Set(tags).count == tags.count, Set(groups).count == groups.count else { throw GraphDataMigrationError.invalidArchive }
        return try GraphDataMigrationRow(record: GraphRecord(id: GraphNodeID(graphID: graphID, rawValue: node),
            type: type, endpoints: endpoints, properties: values.mapValues { try GraphValueCodec.decode($0) },
            tags: Set(tags), groups: Set(groups), createdDate: created), dataVersion: version)
    }
}

package struct GraphDataMigrationPublication: Sendable {
    package let plan: GraphMigrationPlan
    package let rows: [GraphDataMigrationRow]
    package let targetFingerprint: String
    package let maximumArtifactBytes: Int

    package static func fingerprint(_ rows: [GraphDataMigrationRow], maximumBytes: Int) throws -> String {
        let canonical = try rows.sorted { $0.record.id.rawValue.uuidString < $1.record.id.rawValue.uuidString }.map(GraphDataMigrationRecord.init)
        let bytes = try encode(canonical)
        guard bytes.count <= maximumBytes else { throw GraphDataMigrationError.budgetExceeded }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    fileprivate static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

package enum GraphDataMigrationReconciliation: Sendable {
    case committed(GraphMigrationIntent), notApplied, unresolved
}

/// Trusted adapter: local exclusive laboratory only. Native imports must not be active.
package struct GraphDataMigrationAdapter: Sendable {
    package let destinationIdentity: String
    package let snapshot: @Sendable ([GraphNodeID]) async throws -> [GraphDataMigrationRow]
    package let publish: @Sendable (GraphDataMigrationPublication, GraphMigrationIntent) async throws -> GraphMigrationIntent
    package let reconcile: @Sendable (GraphDataMigrationPublication, GraphMigrationIntent) async throws -> GraphDataMigrationReconciliation
    package init(destinationIdentity: String,
                 snapshot: @escaping @Sendable ([GraphNodeID]) async throws -> [GraphDataMigrationRow],
                 publish: @escaping @Sendable (GraphDataMigrationPublication, GraphMigrationIntent) async throws -> GraphMigrationIntent,
                 reconcile: @escaping @Sendable (GraphDataMigrationPublication, GraphMigrationIntent) async throws -> GraphDataMigrationReconciliation) {
        self.destinationIdentity = destinationIdentity; self.snapshot = snapshot
        self.publish = publish; self.reconcile = reconcile
    }
}

private struct GraphDataMigrationArchive: Codable {
    let format: Int
    let descriptor: GraphDataMigrationDescriptor
    let destination: String
    let sourceFingerprint: String
    let targetFingerprint: String
    let records: [GraphDataMigrationRecord]

    func publication() throws -> GraphDataMigrationPublication {
        guard format == 1 else { throw GraphDataMigrationError.invalidArchive }
        let rows = try records.map { try $0.decoded() }
        guard Set(rows.map { $0.record.id }) == Set(descriptor.recordIDs),
              rows.count == descriptor.nodes.count,
              rows.allSatisfy({ $0.dataVersion == descriptor.targetVersion && $0.record.type == descriptor.type
                  && GraphDataMigrationRecord.kindName($0.record.endpoints.kind) == descriptor.kind }),
              try GraphDataMigrationPublication.fingerprint(rows, maximumBytes: descriptor.maximumArtifactBytes) == targetFingerprint else {
            throw GraphDataMigrationError.invalidArchive
        }
        return GraphDataMigrationPublication(plan: GraphMigrationPlan(scope: descriptor.graph.uuidString,
            migrationID: descriptor.id, version: descriptor.revision, sourceFingerprint: sourceFingerprint,
            destinationIdentity: destination, steps: ["publish-data"]), rows: rows,
            targetFingerprint: targetFingerprint, maximumArtifactBytes: descriptor.maximumArtifactBytes)
    }
}

package struct GraphDataMigrationResult: Sendable {
    package enum State: Sendable { case completed, retryRequired }
    package let state: State
    package let operationID: UUID
    package let recordCount: Int
    package let recovered: Bool
}

/// M2a data-only execution. No public opening integration, native-schema plans or cloud pause.
package actor GraphDataMigrationManager {
    package static let shared = GraphDataMigrationManager()
    private var active = Set<String>()
    private init() {}

    package func run(_ definition: GraphDataMigrationDefinition, adapter: GraphDataMigrationAdapter,
                     artifactsAt directory: URL) async throws -> GraphDataMigrationResult {
        try Task.checkCancellation()
        guard directory.isFileURL, !adapter.destinationIdentity.isEmpty else { throw GraphDataMigrationError.invalidDefinition }
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard active.insert(key).inserted else { throw GraphDataMigrationError.busy }
        defer { active.remove(key) }
        let archiveURL = directory.appendingPathComponent("prepared-data.json")
        let journalURL = directory.appendingPathComponent("journal.json")
        let archive: GraphDataMigrationArchive
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= definition.descriptor.maximumArtifactBytes else { throw GraphDataMigrationError.budgetExceeded }
            archive = try JSONDecoder().decode(GraphDataMigrationArchive.self, from: Data(contentsOf: archiveURL))
            guard archive.descriptor == definition.descriptor else { throw GraphDataMigrationError.invalidArchive }
            guard archive.destination == adapter.destinationIdentity else { throw GraphDataMigrationError.destinationMismatch }
        } else {
            guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw GraphDataMigrationError.invalidArchive }
            let source = try await adapter.snapshot(definition.descriptor.recordIDs)
            let descriptor = definition.descriptor
            guard source.count == descriptor.nodes.count, Set(source.map { $0.record.id }) == Set(descriptor.recordIDs),
                  source.allSatisfy({ $0.dataVersion == descriptor.sourceVersion && $0.record.type == descriptor.type
                      && GraphDataMigrationRecord.kindName($0.record.endpoints.kind) == descriptor.kind }) else {
                throw GraphDataMigrationError.sourceFormatMismatch
            }
            let sourceFingerprint = try GraphDataMigrationPublication.fingerprint(source, maximumBytes: descriptor.maximumArtifactBytes)
            var target: [GraphDataMigrationRow] = []
            for row in source {
                try Task.checkCancellation()
                let record = try definition.transform(row.record)
                guard record.id == row.record.id, record.type == row.record.type,
                      record.endpoints == row.record.endpoints, record.createdDate == row.record.createdDate,
                      record.dataVersion == row.record.dataVersion else {
                    throw GraphDataMigrationError.invalidTransformation
                }
                target.append(try GraphDataMigrationRow(record: record, dataVersion: descriptor.targetVersion))
            }
            archive = try GraphDataMigrationArchive(format: 1, descriptor: descriptor, destination: adapter.destinationIdentity,
                sourceFingerprint: sourceFingerprint,
                targetFingerprint: GraphDataMigrationPublication.fingerprint(target, maximumBytes: descriptor.maximumArtifactBytes),
                records: target.map(GraphDataMigrationRecord.init))
            let bytes = try GraphDataMigrationPublication.encode(archive)
            guard bytes.count <= descriptor.maximumArtifactBytes else { throw GraphDataMigrationError.budgetExceeded }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            try bytes.write(to: archiveURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        }
        let publication = try archive.publication()
        let checkpoint = try await GraphMigrationJournal.shared.prepare(at: journalURL, plan: publication.plan)
        if let pending = checkpoint.pending {
            switch try await adapter.reconcile(publication, pending) {
            case .committed(let marker):
                guard marker == pending else { throw GraphDataMigrationError.reconciliationRequired }
                return try await Self.finish(publication, marker: marker, journalURL: journalURL, adapter: adapter, recovered: true)
            case .notApplied:
                _ = try await GraphMigrationJournal.shared.confirmNotApplied(at: journalURL, plan: publication.plan, intent: pending)
                return GraphDataMigrationResult(state: .retryRequired, operationID: pending.operationID,
                                               recordCount: 0, recovered: true)
            case .unresolved: throw GraphDataMigrationError.reconciliationRequired
            }
        }
        if let committed = checkpoint.completed.last {
            return try await Self.finish(publication, marker: committed, journalURL: journalURL, adapter: adapter, recovered: true)
        }
        let intent = try await GraphMigrationJournal.shared.begin(at: journalURL, plan: publication.plan,
            step: "publish-data", resultFingerprint: publication.targetFingerprint)
        try Task.checkCancellation()
        let marker = try await adapter.publish(publication, intent)
        guard marker == intent else { throw GraphDataMigrationError.reconciliationRequired }
        return try await Self.finish(publication, marker: marker, journalURL: journalURL, adapter: adapter, recovered: false)
    }

    private static func finish(_ publication: GraphDataMigrationPublication, marker: GraphMigrationIntent,
                               journalURL: URL, adapter: GraphDataMigrationAdapter, recovered: Bool) async throws -> GraphDataMigrationResult {
        // After commit, finish trusted validation/checkpoint work even if the caller cancels.
        // No consumer transformation runs in this task.
        try await Task.detached {
            guard case .committed(let actual) = try await adapter.reconcile(publication, marker), actual == marker else {
                throw GraphDataMigrationError.reconciliationRequired
            }
            var checkpoint = try await GraphMigrationJournal.shared.confirmCommitted(at: journalURL, plan: publication.plan, marker: marker)
            if checkpoint.state == .prepared {
                checkpoint = try await GraphMigrationJournal.shared.markValidated(at: journalURL, plan: publication.plan)
            }
            if checkpoint.state == .validated {
                checkpoint = try await GraphMigrationJournal.shared.markActivated(at: journalURL, plan: publication.plan)
            }
            guard checkpoint.state == .completed else { throw GraphDataMigrationError.reconciliationRequired }
            return GraphDataMigrationResult(state: .completed, operationID: marker.operationID,
                                           recordCount: publication.rows.count, recovered: recovered)
        }.value
    }
}
