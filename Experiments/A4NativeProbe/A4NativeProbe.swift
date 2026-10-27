import Foundation
import GraphEvo
import UIKit

private struct A4EntityProbe: GraphModel {
    nonisolated static let graphType = "A4.entity"
    nonisolated static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    nonisolated var id: GraphNodeID { record.id }
    nonisolated init(graphRecord: GraphRecord) throws { record = graphRecord }
    nonisolated func graphRecord() throws -> GraphRecord { record }
}

private struct A4EdgeProbe: GraphModel {
    nonisolated static let graphType = "A4.edge"
    nonisolated static let graphKind: GraphNodeKind = .relationship
    let record: GraphRecord
    nonisolated var id: GraphNodeID { record.id }
    nonisolated init(graphRecord: GraphRecord) throws { record = graphRecord }
    nonisolated func graphRecord() throws -> GraphRecord { record }
}

private struct A4ActionProbe: GraphModel {
    nonisolated static let graphType = "A4.action"
    nonisolated static let graphKind: GraphNodeKind = .action
    let record: GraphRecord
    nonisolated var id: GraphNodeID { record.id }
    nonisolated init(graphRecord: GraphRecord) throws { record = graphRecord }
    nonisolated func graphRecord() throws -> GraphRecord { record }
}

/// Disposable demo integration: only synthetic A4 fixtures, no account or invitation material.
@MainActor final class A4NativeProbeViewController: UIViewController {
    private let output = UITextView()
    private var task: Task<Void, Never>?
    private let arguments: [String]
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use the CLI initializer.") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { await run() }
    }

    private struct Case: Codable {
        let a: GraphID
        let b: GraphID
        let aIDs: [GraphNodeID]
        let bIDs: [GraphNodeID]
    }
    private enum ProbeError: Error { case arguments, replay, invalidFixture, unavailableConfiguration }

    private func log(_ message: String) {
        output.text += message + "\n"
        print("A4: " + message)
    }

    private func run() async {
        do {
            guard let flag = arguments.firstIndex(of: "--a4"), arguments.count > flag + 2,
                  let runID = UUID(uuidString: arguments[flag + 2]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  !identifier.isEmpty else { throw ProbeError.arguments }
            let stage = arguments[flag + 1]
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/A4/\(runID.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reportURL = directory.appendingPathComponent("\(stage).txt")
            guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw ProbeError.replay }
            try "reserved\n".write(to: reportURL, atomically: true, encoding: .utf8)
            let caseURL = directory.appendingPathComponent("case.json")
            let reader = stage.hasPrefix("read")
            let storeURL = directory.appendingPathComponent(reader ? "\(stage).sqlite" : "writer.sqlite")
            let database = try await GraphDatabase.openMirrored(at: storeURL, containerIdentifier: identifier)
            log("Opened native mirrored resource; local readiness only.")
            if stage == "seed" {
                guard !FileManager.default.fileExists(atPath: caseURL.path), try await database.graphIDs().isEmpty else {
                    throw ProbeError.replay
                }
                let a = try await database.createGraph(), b = try await database.createGraph()
                let aIDs = try await seed(a, prefix: "A"), bIDs = try await seed(b, prefix: "B")
                let fixture = Case(a: a.id, b: b.id, aIDs: aIDs, bIDs: bIDs)
                try JSONEncoder().encode(fixture).write(to: caseURL, options: .atomic)
                let first = try await database.prepareMirroring(for: a.id)
                log("A native share persisted.")
                let second = try await database.prepareMirroring(for: b.id)
                log("B native share persisted.")
                guard first.zoneName != second.zoneName else { throw ProbeError.invalidFixture }
                try await inspect(database, fixture: fixture, aCount: 5)
                try await a.close(); try await b.close()
            } else {
                let fixture = try JSONDecoder().decode(Case.self, from: Data(contentsOf: caseURL))
                if stage == "reprepare" {
                    let beforeA = try await database.inspectMirroring(for: fixture.a)
                    let beforeB = try await database.inspectMirroring(for: fixture.b)
                    guard beforeA.boundary != nil, beforeB.boundary != nil else { throw ProbeError.invalidFixture }
                    let first = try await database.prepareMirroring(for: fixture.a)
                    let second = try await database.prepareMirroring(for: fixture.b)
                    guard first == beforeA.boundary, second == beforeB.boundary else { throw ProbeError.invalidFixture }
                    log("Repeated preparation reused both existing share/zone identities.")
                    try await inspect(database, fixture: fixture, aCount: 5, edited: true)
                } else if stage == "mutate" {
                    let a = try await database.openGraph(fixture.a)
                    try await a.transaction { scope throws -> Void in
                        for record in try Self.additionalRecords(fixture.a) { try scope.insert(record) }
                        _ = try scope.patch(GraphRecordPatch(id: fixture.aIDs[0], properties: ["label": .set(.string("A-updated"))]))
                    }
                    try await a.close()
                    log("Committed three disconnected members and an existing-node edit; no explicit share call.")
                    try await inspect(database, fixture: fixture, aCount: 8, edited: true)
                } else if stage == "delete" {
                    let a = try await database.openGraph(fixture.a)
                    for record in try Self.additionalRecords(fixture.a) { try await a.delete(record.id) }
                    try await a.close()
                    try await inspect(database, fixture: fixture, aCount: 5, edited: true)
                } else if reader {
                    try await inspect(database, fixture: fixture, aCount: stage == "read-added" ? 8 : 5, edited: stage != "read-initial")
                } else { throw ProbeError.arguments }
            }
            try await database.close()
            log("PASS \(stage)")
            try output.text.write(to: reportURL, atomically: true, encoding: .utf8)
        } catch {
            log("FAIL: \(String(describing: error))")
        }
    }

    private func seed(_ graph: GraphStore, prefix: String) async throws -> [GraphNodeID] {
        let ids = (0..<5).map { _ in graph.makeNodeID() }
        try await graph.transaction { scope throws -> Void in
            for index in 0..<2 {
                try scope.insert(GraphRecord(id: ids[index], type: "A4.entity", properties: ["label": .string("\(prefix)-\(index)"),
                    "binary": .data(Data([0, 255, UInt8(index)]))], tags: ["fixture"], groups: ["A4"]))
            }
            try scope.insert(GraphRecord(id: ids[2], type: "A4.edge", endpoints: .relationship(subject: ids[0], object: ids[1])))
            try scope.insert(GraphRecord(id: ids[3], type: "A4.edge", endpoints: .relationship(subject: ids[1], object: ids[0])))
            try scope.insert(GraphRecord(id: ids[4], type: "A4.action", endpoints: .action(subjects: [ids[0]], objects: [ids[1]])))
        }
        return ids
    }

    nonisolated private static func additionalRecords(_ graphID: GraphID) throws -> [GraphRecord] {
        let ids = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003"]
            .map { GraphNodeID(graphID: graphID, rawValue: UUID(uuidString: $0)!) }
        return try [GraphRecord(id: ids[0], type: "A4.entity", properties: ["label": .string("disconnected")], tags: ["late"], groups: ["A4"]),
                    GraphRecord(id: ids[1], type: "A4.edge", endpoints: .relationship(subject: nil, object: nil)),
                    GraphRecord(id: ids[2], type: "A4.action", endpoints: .action(subjects: [], objects: []))]
    }

    private func inspect(_ database: GraphDatabase, fixture: Case, aCount: Int, edited: Bool = false) async throws {
        // Poll app-visible data and native mappings independently; events are not a completion barrier.
        for attempt in 0..<90 {
            do {
                let ids = try await database.graphIDs()
                guard ids.contains(fixture.a), ids.contains(fixture.b) else { throw ProbeError.invalidFixture }
                let a = try await database.openGraph(fixture.a), b = try await database.openGraph(fixture.b)
                let expectedA = fixture.aIDs + (aCount == 8 ? try Self.additionalRecords(fixture.a).map(\.id) : [])
                let allA = try await a.read { scope in
                    try scope.fetchAll(A4EntityProbe.self).map(\.record)
                        + scope.fetchAll(A4EdgeProbe.self).map(\.record)
                        + scope.fetchAll(A4ActionProbe.self).map(\.record)
                }
                guard allA.count == aCount, Set(allA.map(\.id)) == Set(expectedA) else { throw ProbeError.invalidFixture }
                let first = try expectedA.map { id in
                    guard let record = allA.first(where: { $0.id == id }) else { throw ProbeError.invalidFixture }
                    return record
                }
                let control = try await b.read { scope in try fixture.bIDs.compactMap { try scope.record(for: $0) } }
                let controlCount = try await b.read { scope in
                    try scope.fetchAll(A4EntityProbe.self).count + scope.fetchAll(A4EdgeProbe.self).count + scope.fetchAll(A4ActionProbe.self).count
                }
                try await a.close(); try await b.close()
                guard first.count == aCount, control.count == 5, controlCount == 5,
                      control[0].properties["label"] == .string("B-0"),
                      control[0].properties["binary"] == .data(Data([0, 255, 0])),
                      control[0].tags == ["fixture"], control[0].groups == ["A4"],
                      control[2].endpoints == .relationship(subject: fixture.bIDs[0], object: fixture.bIDs[1]),
                      control[4].endpoints == .action(subjects: [fixture.bIDs[0]], objects: [fixture.bIDs[1]]) else {
                    throw ProbeError.invalidFixture
                }
                let aMapping = try await database.inspectMirroring(for: fixture.a)
                let bMapping = try await database.inspectMirroring(for: fixture.b)
                guard let firstBoundary = aMapping.boundary, let secondBoundary = bMapping.boundary,
                      firstBoundary.zoneName != secondBoundary.zoneName,
                      aMapping.pendingMappingCount == 0, bMapping.pendingMappingCount == 0,
                      aMapping.unexpectedZoneCount == 0, bMapping.unexpectedZoneCount == 0 else {
                    throw ProbeError.invalidFixture
                }
                if edited {
                    guard first[0].properties["label"] == .string("A-updated") else { throw ProbeError.invalidFixture }
                }
                if aCount == 8 {
                    guard first[0].properties["label"] == .string("A-updated"),
                          first[6].endpoints == .relationship(subject: nil, object: nil),
                          first[7].endpoints == .action(subjects: [], objects: []) else { throw ProbeError.invalidFixture }
                }
                log("Verified A=\(first.count), B=\(control.count); native rows A=\(aMapping.nativeObjectCount), B=\(bMapping.nativeObjectCount), all mapped to distinct boundaries.")
                return
            } catch {
                if attempt == 89 { throw error }
                if attempt % 10 == 0 { log("Waiting for app-visible fixture/native mappings (\(attempt)).") }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
}
