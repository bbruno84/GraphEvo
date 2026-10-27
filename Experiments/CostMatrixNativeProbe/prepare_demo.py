#!/usr/bin/env python3
"""Reuse the one-use A6 lifecycle in a disposable demo, adding split-format assertions."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / "A6NativeProbe/prepare_demo.py"),
                str(args.demo), str(args.destination)], check=True)
source = args.destination / "GraphEvoDemo/A6NativeProbe.swift"
text = source.read_text()
needle = "                try await graph.close()\n                let mapping = try await db.inspectMirroring(for: fixture.a)"
assert text.count(needle) == 1, "Inspect upstream A6 verification before generating the matrix probe."
text = text.replace(needle, '''                var expected = [fixture.small.id]
                if !deletion { expected.append(fixture.large.id) }
                if let addition { expected.append(addition.id) }
                let expectedIDs = expected
                try await graph.read { scope in
                    for id in expectedIDs {
                        guard let record = try scope.record(for: id),
                              case .data = record.properties["attachmentMetadata"],
                              case .data = record.properties["content"] else { throw Failure.fixture }
                    }
                }
                try await graph.close()
                let mapping = try await db.inspectMirroring(for: fixture.a)''', 1)
replacement = '                    guard next.id == fixture.large.id, next.revision != fixture.large.revision else { throw Failure.fixture }'
assert text.count(replacement) == 1
text = text.replace(replacement, '                    try write(next, at: root.appendingPathComponent("replacement.json"), run: run)\n' + replacement, 1)
needle = "                let expectedIDs = expected"
assert text.count(needle) == 1
text = text.replace(needle, '''                if replacement && !deletion {
                    guard let report, let flag = arguments.firstIndex(of: "--a6"),
                          let run = UUID(uuidString: arguments[flag + 2]) else { throw Failure.fixture }
                    let expected = try read(GraphAttachmentMetadata.self, at: report.deletingLastPathComponent().appendingPathComponent("replacement.json"), run: run)
                    guard try await graph.attachment(fixture.large.id)?.metadata == expected else { throw Failure.fixture }
                }
                let expectedIDs = expected''', 1)
needle = '    private struct Fixture: Codable {'
assert text.count(needle) == 1
text = text.replace(needle, '''    private struct MatrixOwner: GraphModel {
        static let graphType = "A6.owner"
        static let graphKind: GraphNodeKind = .entity
        let id: GraphNodeID
        init(graphRecord: GraphRecord) throws { id = graphRecord.id }
        func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType) }
    }
    private struct MatrixFile: GraphModel {
        static let graphType = "GraphEvo.Attachment.v1"
        static let graphKind: GraphNodeKind = .entity
        let id: GraphNodeID
        init(graphRecord: GraphRecord) throws { id = graphRecord.id }
        func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType) }
    }
    private struct Fixture: Codable {''', 1)
needle = '                case "invite":'
assert text.count(needle) == 1
text = text.replace(needle, r'''                case "matrix-query-owner", "matrix-query-peer", "matrix-query-owner-fixed", "matrix-query-peer-fixed":
                    let owner = stage.hasPrefix("matrix-query-owner")
                    guard (try await db.graphIDs()).contains(fixture.b) == owner else { throw Failure.fixture }
                    let budget = try GraphQueryBudget(maximumCandidates: 10_000, maximumPropertyBytes: 32 * 1024)
                    let a = try await db.openGraph(fixture.a)
                    guard try await a.query(GraphQuery<MatrixOwner>(budget: budget)).items.isEmpty,
                          try await a.count(GraphQuery<MatrixFile>(budget: budget)).value == 0 else { throw Failure.fixture }
                    try await a.close()
                    if owner {
                        let b = try await db.openGraph(fixture.b)
                        let query = GraphQuery<MatrixOwner>(budget: budget)
                        guard try await b.query(query).items.map(\.id) == [fixture.ownerB],
                              try await b.count(query).value == 1 else { throw Failure.fixture }
                        let files = GraphQuery<MatrixFile>(budget: budget).where(.exists("attachmentMetadata"))
                        let projected = try await b.project(files, properties: ["attachmentMetadata"])
                        guard projected.rows.map(\.id) == [fixture.control.id],
                              try await b.count(files).value == 1 else { throw Failure.fixture }
                        try check(try await b.attachment(fixture.control.id), metadata: fixture.control, size: 512, value: 47)
                        try await b.close()
                    }
                    log("Read-only selective query/count/metadata projection agree; A empty and B control isolated.")
                case "invite":''', 1)
source.write_text(text)
