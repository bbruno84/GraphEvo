import CoreData
import Foundation
import Testing
@testable import GraphEvo

@Suite(.timeLimit(.minutes(2))) struct GraphStoreCopyLaboratoryTests {
    @Test(arguments: GraphStoreCopyLaboratory.Method.allCases)
    func closedCopiesRetainHistoryIdentityExternalContentAndPublishWithoutReplay(method: GraphStoreCopyLaboratory.Method) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MC01-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/store.sqlite"), work = root.appendingPathComponent("work/store.sqlite")
        let baseline = try await GraphDatabase.open(at: source, schema: .nativeIdentity)
        let graph = try await baseline.createGraph(), control = try await baseline.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID(), doomed = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        let controlID = control.makeNodeID()
        try await graph.transaction { scope in
            for id in [a, b, doomed] { try scope.insert(GraphRecord(id: id, type: "MC01.item", properties: ["label": .string("before"), "remove": .integer(1)])) }
            try scope.insert(GraphRecord(id: edge, type: "MC01.edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "MC01.action", endpoints: .action(subjects: [a], objects: [b])))
        }
        _ = try await control.transaction { try $0.insert(GraphRecord(id: controlID, type: "MC01.control", properties: ["keep": .integer(42)])) }
        let input = root.appendingPathComponent("input.bin")
        let bytes = Data(repeating: 173, count: 2 * 1024 * 1024)
        try bytes.write(to: input)
        let attachment = try await graph.importAttachment(from: input, ownedBy: a)
        let removedFile = try await graph.importAttachment(from: input, ownedBy: doomed)
        try await graph.close(); try await control.close(); try await baseline.close()
        let history = try GraphStoreCopyLaboratory.history(at: source)
        #expect(history.transactions > 0 && history.inserts > 0)
        try GraphStoreCopyLaboratory.copyClosed(from: source, to: work, method: method)
        let copied = try GraphStoreCopyLaboratory.history(at: work)
        #expect(copied.storeID == history.storeID)
        #expect(copied.transactions == history.transactions)
        #expect(copied.changes == history.changes)
        let initialDelta = try GraphStoreCopyLaboratory.history(at: work, after: history.lastToken)
        #expect(initialDelta.transactions == 0)
        let working = try await GraphDatabase.open(at: work, schema: .nativeIdentity), draft = try await working.openGraph(graph.id)
        #expect(try await draft.attachment(attachment.id)?.data == bytes)
        let added = draft.makeNodeID(), ephemeral = draft.makeNodeID()
        try await draft.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: a, properties: ["label": .set(.string("after")), "remove": .remove]))
            try scope.insert(GraphRecord(id: added, type: "MC01.item", properties: ["new": .boolean(true)]))
            _ = try scope.patch(GraphRecordPatch(id: edge, endpoints: .relationship(subject: a, object: added)))
            try scope.delete(doomed)
            try scope.insert(GraphRecord(id: ephemeral, type: "MC01.ephemeral"))
            try scope.delete(ephemeral)
        }
        let replacement = Data(repeating: 31, count: 3 * 1024 * 1024)
        try replacement.write(to: input)
        _ = try await draft.replaceAttachment(attachment.id, from: input)
        try await draft.close(); try await working.close()
        let delta = try GraphStoreCopyLaboratory.history(at: work, after: history.lastToken)
        #expect(delta.transactions > 0 && delta.inserts > 0 && delta.updates > 0 && delta.deletes > 0)
        // The original remains unchanged until explicit publication with all owners closed.
        let untouched = try await GraphDatabase.openReadOnly(at: source, schema: .nativeIdentity), original = try await untouched.openGraph(graph.id)
        #expect(try await original.read { try $0.record(for: a)?.properties["label"] } == .string("before"))
        #expect(try await original.attachment(removedFile.id) != nil)
        try await original.close(); try await untouched.close()
        try GraphStoreCopyLaboratory.replaceClosed(from: work, at: source)
        let publishedHistory = try GraphStoreCopyLaboratory.history(at: source, after: history.lastToken)
        #expect(publishedHistory.storeID == history.storeID)
        #expect(publishedHistory.transactions == delta.transactions && publishedHistory.changes == delta.changes)
        let published = try await GraphDatabase.open(at: source, schema: .nativeIdentity), final = try await published.openGraph(graph.id)
        let keep = try await published.openGraph(control.id)
        #expect(try await final.read { try $0.record(for: a)?.properties["label"] } == .string("after"))
        #expect(try await final.read { try $0.record(for: a)?.properties["remove"] } == nil)
        #expect(try await final.read { try $0.record(for: added) } != nil)
        #expect(try await final.read { try $0.record(for: ephemeral) } == nil)
        #expect(try await final.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: a, object: added))
        #expect(try await final.read { try $0.record(for: action)?.endpoints } == .action(subjects: [a], objects: [b]))
        #expect(try await final.attachment(attachment.id)?.data == replacement)
        #expect(try await final.attachment(removedFile.id) == nil)
        #expect(try await keep.read { try $0.record(for: controlID)?.properties["keep"] } == .integer(42))
        #expect(try await published.validateIntegrity(of: graph.id) == 6)
        try await final.close(); try await keep.close(); try await published.close()
        #expect(try GraphStoreCopyLaboratory.history(at: source).transactions == history.transactions + delta.transactions)
    }
}

extension GraphStoreCopyLaboratoryTests {
    @Test func replacementIsWholeStoreAndDoesNotMergeEditsMadeOnTheOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MC01-Stale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/store.sqlite"), work = root.appendingPathComponent("work/store.sqlite")
        let db = try await GraphDatabase.open(at: source, schema: .nativeIdentity), control = try await db.createGraph()
        let id = control.makeNodeID()
        _ = try await control.transaction { try $0.insert(GraphRecord(id: id, type: "control", properties: ["value": .integer(1)])) }
        try await control.close(); try await db.close()
        try GraphStoreCopyLaboratory.copyClosed(from: source, to: work, method: .coreData)
        let changed = try await GraphDatabase.open(at: source, schema: .nativeIdentity), writer = try await changed.openGraph(control.id)
        _ = try await writer.transaction { try $0.patch(GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))])) }
        try await writer.close(); try await changed.close()
        // Deliberately demonstrate the unsafe case, using disposable data only.
        // Store replacement has no graph-level merge or stale-source refusal contract.
        try GraphStoreCopyLaboratory.replaceClosed(from: work, at: source)
        let reopened = try await GraphDatabase.open(at: source, schema: .nativeIdentity), reader = try await reopened.openGraph(control.id)
        #expect(try await reader.read { try $0.record(for: id)?.properties["value"] } == .integer(1))
        try await reader.close(); try await reopened.close()
    }

    @Test func copyRefusesExistingDestinationsAndUnrelatedModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MC01-Refusal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/store.sqlite"), destination = root.appendingPathComponent("copy/store.sqlite")
        let current = try await GraphDatabase.open(at: source)
        try await current.close()
        #expect(throws: GraphStoreCopyLaboratory.Failure.incompatible) {
            try GraphStoreCopyLaboratory.copyClosed(from: source, to: destination, method: .coreData)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = destination.deletingLastPathComponent().appendingPathComponent("keep")
        try Data([42]).write(to: marker)
        #expect(throws: GraphStoreCopyLaboratory.Failure.destinationExists) {
            try GraphStoreCopyLaboratory.copyClosed(from: source, to: destination, method: .directory)
        }
        #expect(try Data(contentsOf: marker) == Data([42]))
    }
}
