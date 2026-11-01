import Foundation
import GraphEvoModel
import GraphEvoStore

// Laboratory consumer code, not a library registry, executor or public API.
struct ConsumerMigrationIDs: Sendable {
    let graph: GraphID
    func node(_ salt: UInt8) -> GraphNodeID {
        var bytes = graph.rawValue.uuid; bytes.15 ^= salt
        return .init(graphID: graph, rawValue: UUID(uuid: bytes))
    }
    var original: Set<GraphNodeID> { Set((64...68).map { node(UInt8($0)) }) }
    var final: Set<GraphNodeID> { Set([64, 67, 80, 81, 82].map { node(UInt8($0)) }) }
}

struct ConsumerMigrationRequest: Codable { let graphID: GraphID; let id: UUID }

enum ConsumerMigrationFailure: Error { case invalidJournal, invalidState, invalidData, injected }
enum ConsumerMigrationFault: Sendable { case afterBegin, afterTransformation, afterPublication, afterLedgerCompletion }
struct ConsumerMigrationJournal: Codable, Sendable {
    let format: Int
    let graphID: GraphID
    let operation: UUID
    var workspace: UUID?
    var phase: String
    var receipt: GraphMigrationPublicationReceipt?
}

actor ConsumerMigrationExample {
    let manager: GraphContextManager
    let configuration: GraphCloudConfiguration
    let ids: ConsumerMigrationIDs
    let directory: URL
    private var working: GraphMigrationWorkspace?
    init(manager: GraphContextManager, configuration: GraphCloudConfiguration, ids: ConsumerMigrationIDs, directory: URL) {
        self.manager = manager; self.configuration = configuration; self.ids = ids; self.directory = directory
    }
    private var journalURL: URL { directory.appendingPathComponent("consumer-migration.json") }
    private var workspaceURL: URL { directory.appendingPathComponent("Working") }
    private var backupsURL: URL { directory.appendingPathComponent("Backups") }
    func journal() throws -> ConsumerMigrationJournal {
        let data = try Data(contentsOf: journalURL)
        guard data.count <= 16 * 1024 else { throw ConsumerMigrationFailure.invalidJournal }
        let value = try JSONDecoder().decode(ConsumerMigrationJournal.self, from: data)
        guard value.format == 1, value.graphID == ids.graph,
              ["requested", "prepared", "sealed", "committed", "completed"].contains(value.phase) else { throw ConsumerMigrationFailure.invalidJournal }
        guard value.phase == "requested" || value.workspace != nil,
              value.receipt == nil || (value.receipt?.workspaceID == value.workspace && value.receipt?.graphID == ids.graph),
              !["committed", "completed"].contains(value.phase) || value.receipt != nil else { throw ConsumerMigrationFailure.invalidJournal }
        return value
    }
    private func save(_ journal: ConsumerMigrationJournal) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 16 * 1024 else { throw ConsumerMigrationFailure.invalidJournal }
        try data.write(to: journalURL, options: .atomic)
    }
    private func synchronizeLedger() async throws -> GraphLedgerStatus {
        let result = try await manager.reconcileGraphLedger(for: ids.graph, configuration: configuration)
        // Recovery-required local intent is evidence to inspect, not a confirmed remote projection.
        guard result.state == .recoveryRequired || (result.state == .idle &&
              (result.confirmedRevision == result.ledger?.revision ||
                (result.confirmedRevision == nil && result.ledger?.current == nil))) else { throw ConsumerMigrationFailure.invalidState }
        return result
    }
    private func ledger() async throws -> GraphLedger {
        guard let value = try await synchronizeLedger().ledger else { throw ConsumerMigrationFailure.invalidState }
        return value
    }
    private func recoverLedger(_ journal: ConsumerMigrationJournal) async throws {
        let local = try await manager.graphLedger(for: ids.graph, configuration: configuration)
        guard local.ledger?.current?.id == journal.operation else { throw ConsumerMigrationFailure.invalidState }
        if local.state == .recoveryRequired {
            _ = try await manager.updateGraphLedger(for: ids.graph, configuration: configuration,
                expectedRevision: local.ledger?.revision, mutation: .resume(operation: journal.operation))
        }
        _ = try await synchronizeLedger()
    }
    func prepare(fault: ConsumerMigrationFault? = nil) async throws {
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            let requestURL = directory.appendingPathComponent("consumer-request.json")
            if !FileManager.default.fileExists(atPath: requestURL.path) {
                try JSONEncoder().encode(ConsumerMigrationRequest(graphID: ids.graph, id: UUID())).write(to: requestURL, options: .withoutOverwriting)
            }
            let request = try JSONDecoder().decode(ConsumerMigrationRequest.self, from: Data(contentsOf: requestURL))
            guard request.graphID == ids.graph else { throw ConsumerMigrationFailure.invalidJournal }
            let information = try JSONSerialization.data(withJSONObject: ["example": "invoice-repair", "request": request.id.uuidString], options: [.sortedKeys])
            let current = try await ledger()
            // Match the durable consumer request; a foreign running operation must not be adopted.
            let operation: UUID
            if let running = current.current, running.state == .running {
                guard running.kind == "example.invoice-repair",
                      running.information == information else { throw ConsumerMigrationFailure.invalidState }
                operation = running.id
            } else {
                let begun = try await manager.updateGraphLedger(for: ids.graph, configuration: configuration,
                    expectedRevision: current.revision, mutation: .begin(kind: "example.invoice-repair", phase: "preparing",
                        information: information))
                guard let value = begun.ledger?.current?.id else { throw ConsumerMigrationFailure.invalidState }
                operation = value
            }
            if fault == .afterBegin { throw ConsumerMigrationFailure.injected }
            try save(.init(format: 1, graphID: ids.graph, operation: operation, workspace: nil, phase: "requested", receipt: nil))
        }
        var value = try journal()
        try await recoverLedger(value)
        if working == nil {
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                working = try await manager.openMigrationWorkspace(for: ids.graph, at: workspaceURL)
            } else {
                guard value.workspace == nil, value.phase == "requested" else { throw ConsumerMigrationFailure.invalidState }
                working = try await manager.prepareMigrationWorkspace(for: ids.graph, at: workspaceURL)
            }
        }
        guard let working, value.workspace == nil || value.workspace == working.id else { throw ConsumerMigrationFailure.invalidState }
        value.workspace = working.id
        if value.phase == "requested" { value.phase = "prepared" }
        try save(value)
    }
    @discardableResult func transformAndSeal(fault: ConsumerMigrationFault? = nil) async throws -> Bool {
        try await prepare()
        let value = try journal()
        guard let working else { throw ConsumerMigrationFailure.invalidState }
        let a = ids.node(64), b = ids.node(65), category = ids.node(80), edge = ids.node(81), file = ids.node(82), operation = value.operation
        let marker = try await working.graph.read { try $0.record(for: a)?.properties["consumerRepair"] }
        var transformed = false
        if marker == nil {
            guard value.phase == "prepared" else { throw ConsumerMigrationFailure.invalidState }
            let attachment = try GraphAttachmentPayload(id: file, ownerID: a, fileName: "receipt.bin", contentType: "public.data",
                data: Data(repeating: 92, count: 2 * 1024 * 1024))
            try await working.graph.transaction { scope in
                guard try scope.record(for: a)?.properties["legacyCents"] == .string("1234") else { throw ConsumerMigrationFailure.invalidData }
                _ = try scope.patch(.init(id: a, properties: ["legacyCents": .remove, "amountCents": .set(.integer(1234)),
                    "consumerRepair": .set(.uuid(operation))], addingTags: ["repaired"], removingTags: ["legacy"]))
                try scope.delete(b)
                try scope.insert(GraphRecord(id: category, type: "Example.Category", properties: ["name": .string("Household")]))
                try scope.insert(GraphRecord(id: edge, type: "Example.Categorized", endpoints: .relationship(subject: a, object: category)))
                _ = try scope.insert(attachment)
            }
            transformed = true
            if fault == .afterTransformation { throw ConsumerMigrationFailure.injected }
        } else if marker != .uuid(operation) { throw ConsumerMigrationFailure.invalidData }
        try await Self.validate(working.graph, ids: ids, operation: operation)
        if ["committed", "completed"].contains(value.phase) { return false }
        _ = try await working.seal()
        var sealed = try journal(); sealed.phase = "sealed"; try save(sealed)
        _ = try await manager.updateGraphLedger(for: ids.graph, configuration: configuration,
            mutation: .progress(operation: operation, phase: "validated"))
        _ = try await synchronizeLedger()
        return transformed
    }
    func publish(fault: ConsumerMigrationFault? = nil) async throws -> GraphMigrationPublicationResult {
        try await prepare()
        var value = try journal()
        guard let working, ["sealed", "committed", "completed"].contains(value.phase) else { throw ConsumerMigrationFailure.invalidState }
        let result = try await manager.publishMigrationWorkspace(working, backupsIn: backupsURL, reason: "Invoice repair: validated before publication")
        if fault == .afterPublication { throw ConsumerMigrationFailure.injected }
        if let previous = value.receipt, previous != result.receipt { throw ConsumerMigrationFailure.invalidState }
        value.receipt = result.receipt
        if value.phase != "completed" { value.phase = "committed" }
        try save(value)
        return result
    }
    func completeAfterConsumerVerification(fault: ConsumerMigrationFault? = nil) async throws {
        var value = try journal()
        guard let receipt = value.receipt, let workspace = value.workspace,
              ["committed", "completed"].contains(value.phase) else { throw ConsumerMigrationFailure.invalidState }
        try await recoverLedger(value)
        let current = try await ledger()
        guard current.current?.id == value.operation else { throw ConsumerMigrationFailure.invalidState }
        if current.current?.state != .succeeded {
            let information = try JSONSerialization.data(withJSONObject: ["example": "invoice-repair", "workspace": workspace.uuidString,
                "backup": receipt.backupID.uuidString, "localCommit": true], options: [.sortedKeys])
            _ = try await manager.updateGraphLedger(for: ids.graph, configuration: configuration,
                mutation: .operationInformation(operation: value.operation, json: information))
            _ = try await manager.updateGraphLedger(for: ids.graph, configuration: configuration,
                mutation: .finish(operation: value.operation, outcome: .succeeded, summary: "Consumer verification completed"))
            _ = try await synchronizeLedger()
        }
        if fault == .afterLedgerCompletion { throw ConsumerMigrationFailure.injected }
        value.phase = "completed"; try save(value)
    }
    func close() async throws { try await working?.close(); working = nil }
    static func seed(_ graph: GraphStore, ids: ConsumerMigrationIDs) async throws {
        let a = ids.node(64), b = ids.node(65), edge = ids.node(66), action = ids.node(67)
        let file = try GraphAttachmentPayload(id: ids.node(68), ownerID: edge, fileName: "legacy.bin", contentType: "public.data",
            data: Data(repeating: 91, count: 2 * 1024 * 1024))
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "Example.Invoice", properties: ["legacyCents": .string("1234")], tags: ["legacy"]))
            try scope.insert(GraphRecord(id: b, type: "Example.Obsolete"))
            try scope.insert(GraphRecord(id: edge, type: "Example.LegacyEdge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "Example.Action", endpoints: .action(subjects: [a,b], objects: [a])))
            _ = try scope.insert(file)
        }
    }
    static func validate(_ graph: GraphStore, ids: ConsumerMigrationIDs, operation: UUID) async throws {
        let a = ids.node(64), b = ids.node(65), oldEdge = ids.node(66), action = ids.node(67), oldFile = ids.node(68)
        let category = ids.node(80), edge = ids.node(81), file = ids.node(82)
        try await graph.read { scope in
            guard let invoice = try scope.record(for: a), invoice.properties["amountCents"] == .integer(1234),
                  invoice.properties["consumerRepair"] == .uuid(operation), invoice.properties["legacyCents"] == nil,
                  invoice.tags == ["repaired"], try scope.record(for: b) == nil, try scope.record(for: oldEdge) == nil,
                  try scope.record(for: oldFile) == nil,
                  try scope.record(for: category)?.properties["name"] == .string("Household"),
                  try scope.record(for: edge)?.endpoints == .relationship(subject: a, object: category),
                  try scope.record(for: action)?.endpoints == .action(subjects: [a], objects: [a]) else { throw ConsumerMigrationFailure.invalidData }
        }
        guard try await graph.attachment(file)?.data == Data(repeating: 92, count: 2 * 1024 * 1024) else { throw ConsumerMigrationFailure.invalidData }
    }
}
