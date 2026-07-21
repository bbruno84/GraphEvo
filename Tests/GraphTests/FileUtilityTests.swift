import XCTest
@testable import Graph

final class FileUtilityTests: XCTestCase {
    func testFileUtilityRoundTripClassificationAndDirectoryListing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-File-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var createResult: (Bool, Error?)?
        File.createDirectoryAtPath(root, withIntermediateDirectories: true, attributes: nil) {
            createResult = ($0, $1)
        }
        XCTAssertEqual(createResult?.0, true)
        XCTAssertNil(createResult?.1)

        File.writeToPath(root, name: "note.txt", value: "hello") { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
        }
        let noteURL = root.appendingPathComponent("note.txt")
        XCTAssertTrue(File.fileExistsAtPath(noteURL))
        XCTAssertTrue(File.isWritableFileAtPath(noteURL))
        if case .text = File.fileType(noteURL) {
        } else {
            XCTFail("A .txt file must be classified as text")
        }
        if case .directory = File.fileType(root) {
        } else {
            XCTFail("A directory must be classified as directory")
        }

        var readValue: String?
        var readError: Error?
        File.readFromPath(noteURL) { value, error in
            readValue = value
            readError = error
        }
        XCTAssertEqual(readValue, "hello")
        XCTAssertNil(readError)

        var contents: [URL]?
        File.contentsOfDirectoryAtPath(root) { value, error in
            contents = value
            XCTAssertNil(error)
        }
        XCTAssertEqual(contents?.map(\.lastPathComponent), ["note.txt"])
        XCTAssertTrue(File.contentsEqualAtPath(noteURL, andPath: noteURL))

        var removeResult: (Bool?, Error?)?
        File.removeItemAtPath(noteURL) { success, error in
            removeResult = (success, error)
        }
        XCTAssertEqual(removeResult?.0, true)
        XCTAssertNil(removeResult?.1)
        XCTAssertFalse(File.fileExistsAtPath(noteURL))
    }

    func testFileUtilityReportsFailures() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Missing-\(UUID().uuidString).txt")
        var readError: Error?
        File.readFromPath(missing) { value, error in
            XCTAssertNil(value)
            readError = error
        }
        XCTAssertNotNil(readError)

        var removeResult: (Bool?, Error?)?
        File.removeItemAtPath(missing) { success, error in
            removeResult = (success, error)
        }
        XCTAssertNil(removeResult?.0)
        XCTAssertNotNil(removeResult?.1)
        if case .text = File.fileType(missing) {
        } else {
            XCTFail("The extension should classify a missing .txt path as text")
        }
        XCTAssertNil(File.path(.applicationDirectory, path: "unsupported"))
    }

    func testFileExtensionMappingsAndClassification() {
        XCTAssertEqual(VideoExtensionToString(.mov), "mov")
        XCTAssertEqual(VideoExtensionToString(.m4v), "m4v")
        XCTAssertEqual(VideoExtensionToString(.mp4), "mp4")
        XCTAssertEqual(ImageExtensionToString(.png), "png")
        XCTAssertEqual(ImageExtensionToString(.jpg), "jpg")
        XCTAssertEqual(ImageExtensionToString(.jpeg), "jpeg")
        XCTAssertEqual(ImageExtensionToString(.tiff), "tiff")
        XCTAssertEqual(ImageExtensionToString(.gif), "gif")
        XCTAssertEqual(TextExtensionToString(.txt), "txt")
        XCTAssertEqual(TextExtensionToString(.rtf), "rtf")
        XCTAssertEqual(TextExtensionToString(.html), "html")
        XCTAssertEqual(SQLiteExtensionToString(.sqLite), "sqlite")
        XCTAssertEqual(SQLiteExtensionToString(.sqLiteSHM), "sqlite-shm")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Classification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for ext in ["png", "jpg", "jpeg", "gif"] {
            XCTAssertEqual(File.fileType(root.appendingPathComponent("asset.\(ext)")), .image)
        }
        for ext in ["mov", "m4v", "mp4"] {
            XCTAssertEqual(File.fileType(root.appendingPathComponent("movie.\(ext)")), .video)
        }
        for ext in ["txt", "rtf", "html"] {
            XCTAssertEqual(File.fileType(root.appendingPathComponent("document.\(ext)")), .text)
        }
        XCTAssertEqual(File.fileType(root.appendingPathComponent("store.sqlite")), .sqLite)
        XCTAssertEqual(File.fileType(root.appendingPathComponent("store.sqlite-shm")), .sqLite)
        XCTAssertEqual(File.fileType(root.appendingPathComponent("unknown.bin")), .unknown)
        XCTAssertEqual(File.path(.documentDirectory, path: "GraphCK"), File.documentDirectoryPath?.appendingPathComponent("GraphCK"))
        XCTAssertEqual(File.path(.libraryDirectory, path: "GraphCK"), File.libraryDirectoryPath?.appendingPathComponent("GraphCK"))
        XCTAssertEqual(File.path(.cachesDirectory, path: "GraphCK"), File.cachesDirectoryPath?.appendingPathComponent("GraphCK"))
        XCTAssertEqual(File.path(.applicationSupportDirectory, path: "GraphCK"), File.applicationSupportDirectoryPath?.appendingPathComponent("GraphCK"))
    }
}
