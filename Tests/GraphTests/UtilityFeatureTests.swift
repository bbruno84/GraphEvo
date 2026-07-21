import XCTest
import CoreData
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

    func testStoreMetadataRoundTripAndGenericValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "MetadataRoundTrip"
        configuration.location = directory
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.create())
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: configuration.resolvedStoreURL,
            options: [:]
        )
        try coordinator.remove(store)

        let versions = GraphStoreConfiguration.Versions(graphModel: 7, appData: 11)
        try GraphStoreMetadata.write(versions, to: configuration, model: Model.create())

        XCTAssertEqual(try GraphStoreMetadata.read(from: configuration), versions)
        try GraphStoreMetadata.writeValue(true, forKey: "GraphCK.TestFlag", to: configuration, model: Model.create())
        XCTAssertTrue(GraphStoreMetadata.boolValue(forKey: "GraphCK.TestFlag", from: configuration))
        XCTAssertTrue(GraphStoreMetadata.listAllKeys(from: configuration).contains("GraphCK.TestFlag"))

        try GraphStoreMetadata.removeValue(forKey: "GraphCK.TestFlag", to: configuration, model: Model.create())
        XCTAssertNil(GraphStoreMetadata.readValue(forKey: "GraphCK.TestFlag", from: configuration) as Bool?)
        XCTAssertFalse(GraphStoreMetadata.boolValue(forKey: "GraphCK.TestFlag", from: configuration))
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

    func testMigrationBackupFileConflictPolicies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-BackupFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("baseline.zip")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try Data("v1".utf8).write(to: source)

        let first = try MigrationBackupManager.backupFile(
            at: source,
            migrationID: "FileMigration",
            conflictPolicy: .duplicate,
            rootOverride: backupRoot
        )
        try Data("v2".utf8).write(to: source)

        let skipped = try MigrationBackupManager.backupFile(
            at: source,
            migrationID: "FileMigration",
            conflictPolicy: .skip,
            rootOverride: backupRoot
        )
        XCTAssertEqual(skipped.folderURL, first.folderURL)
        XCTAssertEqual(try Data(contentsOf: first.folderURL.appendingPathComponent("baseline.zip")), Data("v1".utf8))

        let duplicated = try MigrationBackupManager.backupFile(
            at: source,
            migrationID: "FileMigration",
            conflictPolicy: .duplicate,
            rootOverride: backupRoot
        )
        XCTAssertNotEqual(duplicated.folderURL, first.folderURL)
        XCTAssertEqual(try Data(contentsOf: duplicated.folderURL.appendingPathComponent("baseline.zip")), Data("v2".utf8))

        try Data("v3".utf8).write(to: source)
        let overwritten = try MigrationBackupManager.backupFile(
            at: source,
            migrationID: "FileMigration",
            conflictPolicy: .overwrite,
            rootOverride: backupRoot
        )
        XCTAssertEqual(overwritten.folderURL, first.folderURL)
        XCTAssertEqual(try Data(contentsOf: first.folderURL.appendingPathComponent("baseline.zip")), Data("v3".utf8))
    }

    func testMigrationBackupMissingSourceFailsAndRestoreCanSkipExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-BackupErrors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing.zip")
        XCTAssertThrowsError(
            try MigrationBackupManager.backupFile(
                at: missing,
                migrationID: "MissingSource",
                rootOverride: root.appendingPathComponent("backups", isDirectory: true)
            )
        )

        let source = root.appendingPathComponent("source.sqlite")
        try Data("backup".utf8).write(to: source)
        let result = try MigrationBackupManager.backupFile(
            at: source,
            migrationID: "RestoreSkip",
            rootOverride: root.appendingPathComponent("backups", isDirectory: true)
        )
        try Data("current".utf8).write(to: source)

        try MigrationBackupManager.restoreToOriginalLocation(
            descriptor: result.descriptor,
            from: result.folderURL,
            overwriteExisting: false
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("current".utf8))
    }
}
