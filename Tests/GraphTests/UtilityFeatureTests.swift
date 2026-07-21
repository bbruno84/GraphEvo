import XCTest
@testable import Graph

final class UtilityFeatureTests: XCTestCase {
    func testAnyCodableNestedJSONRoundTripAndUnsupportedValue() throws {
        let original: [String: Any] = [
            "name": "GraphCK",
            "count": 3,
            "enabled": true,
            "items": ["a", "b"]
        ]
        let codable = try XCTUnwrap(AnyCodable(original))
        let encoded = try JSONEncoder().encode(codable)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let unwrapped = try XCTUnwrap(decoded.unwrap() as? [String: Any])

        XCTAssertEqual(unwrapped["name"] as? String, "GraphCK")
        XCTAssertEqual(unwrapped["count"] as? Int, 3)
        XCTAssertEqual(unwrapped["enabled"] as? Bool, true)
        XCTAssertEqual(unwrapped["items"] as? [String], ["a", "b"])
        XCTAssertNil(AnyCodable(NSUUID()))
    }

    func testGraphJSONRoundTripAndMutation() throws {
        let original = "{\"name\":\"GraphCK\",\"items\":[1,2,3]}"
        guard var json = GraphJSON.parse(original) else {
            return XCTFail("Valid JSON must be parsed")
        }

        XCTAssertEqual(json["name"].asString, "GraphCK")
        XCTAssertEqual(json["items"].asArray?.count, 3)
        XCTAssertEqual(json["items"][1].asInt, 2)

        json["name"] = GraphJSON("GraphCK-v1")
        XCTAssertEqual(json["name"].asString, "GraphCK-v1")
        XCTAssertEqual(GraphJSON.parse(json.description), json)
        XCTAssertNil(GraphJSON.parse("not-json"))
    }

    func testStoreMetadataUpgradeRules() {
        let current = GraphStoreConfiguration.Versions(graphModel: 2, appData: 3)

        XCTAssertFalse(GraphStoreMetadata.needsUpgrade(current: current, required: current))
        XCTAssertTrue(
            GraphStoreMetadata.needsUpgrade(
                current: current,
                required: .init(graphModel: 3, appData: 3)
            )
        )
        XCTAssertTrue(
            GraphStoreMetadata.needsUpgrade(
                current: .init(graphModel: nil, appData: nil),
                required: .init(graphModel: 1, appData: 1)
            )
        )
    }

    func testMigrationBackupStoreFindAndRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Backup-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = sourceDirectory.appendingPathComponent("GraphCK.sqlite")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let result = try MigrationBackupManager.backupStore(
            at: storeURL,
            migrationID: "TestMigration",
            label: "before",
            rootOverride: backupRoot
        )

        XCTAssertEqual(result.descriptor.migrationID, "TestMigration")
        XCTAssertEqual(
            Set(result.descriptor.files),
            Set([storeURL.lastPathComponent, walURL.lastPathComponent, shmURL.lastPathComponent])
        )

        let found = try MigrationBackupManager.findBackupsForStore(
            migrationID: "TestMigration",
            storeURL: storeURL,
            rootOverride: backupRoot
        )
        XCTAssertEqual(found.count, 1)

        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.removeItem(at: walURL)
        try FileManager.default.removeItem(at: shmURL)
        try MigrationBackupManager.restoreToOriginalLocation(
            descriptor: result.descriptor,
            from: result.folderURL
        )

        XCTAssertEqual(try Data(contentsOf: storeURL), Data("store".utf8))
        XCTAssertEqual(try Data(contentsOf: walURL), Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: shmURL), Data("shm".utf8))
    }
}
