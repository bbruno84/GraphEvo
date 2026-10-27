import CoreData
import Foundation
import Testing
@testable import GraphEvo
import GraphEvoRuntime

@Suite struct GraphSharingJournalTests {
    @Test @MainActor func interruptedIntentIsRecoveredAndAnotherOperationCannotEraseIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphSharingJournal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = directory.appendingPathComponent("Shared.sqlite")
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.userInfo[StoreNativeContext.sharedURLKey] = shared
        let id = GraphID(), record = try GraphRecord(id: GraphNodeID(graphID: id), type: "node", properties: ["value": .string("retained")])
        let plan = try GraphSharedInsertionPlan(graphID: id, records: [record])
        try GraphSharedInsertionJournal.reserve(plan, context: context)
        let reopened = try #require(try GraphSharedInsertionJournal.read(graphID: id, context: context))
        #expect(reopened.operationID == plan.operationID)
        #expect(try reopened.records() == [record])
        let another = try GraphSharedInsertionPlan(graphID: id, records: [record])
        #expect(throws: GraphStoreError.self) { try GraphSharedInsertionJournal.reserve(another, context: context) }
        #expect(try !GraphSharedInsertionJournal.clearIfOwned(operationID: another.operationID, graphID: id, context: context))
        #expect(try GraphSharedInsertionJournal.read(graphID: id, context: context)?.operationID == plan.operationID)
        #expect(try GraphSharedInsertionJournal.clearIfOwned(operationID: plan.operationID, graphID: id, context: context))
        #expect(try GraphSharedInsertionJournal.read(graphID: id, context: context) == nil)
    }

    @Test @MainActor func storeBackupAndRestoreCarryTheLocalOperationLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphSharingBackup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shared = directory.appendingPathComponent("Shared.sqlite")
        // Backup treats SQLite content as opaque bytes; no coordinator opens this file.
        try Data([1, 2, 3]).write(to: shared)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.userInfo[StoreNativeContext.sharedURLKey] = shared
        let id = GraphID(), record = try GraphRecord(id: GraphNodeID(graphID: id), type: "node")
        let plan = try GraphSharedInsertionPlan(graphID: id, records: [record])
        try GraphSharedInsertionJournal.reserve(plan, context: context)
        let backup = try MigrationBackupManager.backupStore(at: shared, migrationID: "journal", rootOverride: directory.appendingPathComponent("Backups"))
        #expect(backup.descriptor.files.contains("Shared.sqlite.graphevo-operations"))
        try FileManager.default.removeItem(at: GraphSharedInsertionJournal.folder(for: shared))
        try MigrationBackupManager.restoreToOriginalLocation(descriptor: backup.descriptor, from: backup.folderURL)
        #expect(try GraphSharedInsertionJournal.read(graphID: id, context: context)?.operationID == plan.operationID)
    }

    @Test @MainActor func malformedJournalFailsVisiblyInsteadOfStartingAnotherInsertion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphSharingMalformed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.userInfo[StoreNativeContext.sharedURLKey] = directory.appendingPathComponent("Shared.sqlite")
        let id = GraphID(), path = try GraphSharedInsertionJournal.url(graphID: id, context: context)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: path)
        #expect(throws: (any Error).self) { try GraphSharedInsertionJournal.read(graphID: id, context: context) }
        #expect(throws: (any Error).self) { try GraphSharedInsertionJournal.clearIfOwned(operationID: UUID(), graphID: id, context: context) }
        #expect(try Data(contentsOf: path) == Data("invalid".utf8))
    }
}
