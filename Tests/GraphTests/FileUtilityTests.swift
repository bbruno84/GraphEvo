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
}
