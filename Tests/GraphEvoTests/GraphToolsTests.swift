import XCTest
import PDFKit
import UIKit
@testable import GraphEvo

final class GraphToolsTests: XCTestCase {
    func testDataKindRecognizesSupportedHeadersAndUnknownData() {
        XCTAssertEqual(GraphTools.dataKind(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "PNG (raw)")
        XCTAssertEqual(GraphTools.dataKind(for: Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])), "PDF (raw)")
        XCTAssertEqual(GraphTools.dataKind(for: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])), "JPEG (raw)")
        XCTAssertEqual(GraphTools.dataKind(for: Data("bplist00".utf8)), "NSKeyedArchive/Plist")
        XCTAssertEqual(GraphTools.dataKind(for: Data("unknown".utf8)), "Unknown")
        XCTAssertEqual(GraphTools.dataHexHeader(Data([0x01, 0xAB, 0xFF]), count: 2), "01 AB")
    }

    func testExportAndDiagnosticHelpersPreserveLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sqliteURL = root.appendingPathComponent("Graph.sqlite")
        let walURL = URL(fileURLWithPath: sqliteURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: sqliteURL.path + "-shm")
        try Data("sqlite".utf8).write(to: sqliteURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let export = try XCTUnwrap(GraphTools.exportMigratedDB(
            to: "GraphCK-Export-\(UUID().uuidString)",
            sqliteURL: sqliteURL
        ))
        defer { try? FileManager.default.removeItem(at: export) }

        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("Graph.sqlite")), Data("sqlite".utf8))
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("Graph.sqlite-wal")), Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("Graph.sqlite-shm")), Data("shm".utf8))

        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { renderer in
            UIColor.systemBlue.setFill()
            renderer.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
        }
        let imageName = "GraphCK-Image-\(UUID().uuidString)"
        let imageURL = try XCTUnwrap(GraphTools.saveUIImageToDisk(image, named: imageName))
        defer { try? FileManager.default.removeItem(at: imageURL) }
        XCTAssertEqual(try Data(contentsOf: imageURL), try XCTUnwrap(image.pngData()))

        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let documentName = "GraphCK-PDF-\(UUID().uuidString)"
        let documentURL = try XCTUnwrap(GraphTools.saveDocumentToDisk(document, named: documentName))
        defer { try? FileManager.default.removeItem(at: documentURL) }
        let reopenedDocument = try XCTUnwrap(PDFDocument(url: documentURL))
        XCTAssertEqual(reopenedDocument.pageCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(reopenedDocument.dataRepresentation()).count, 0)

    }
}
