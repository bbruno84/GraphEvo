//
//  MigrationBackupManager.swift
//  Graph
//
//  Created by Valerio Buriani on 07/11/25.
//


import Foundation

/// Manages backup and restoration of files used by migrations.
/// (store SQLite + WAL/SHM, baseline.zip, ecc).
///
/// Goals:
/// - One reusable API for all migrations (`MigrationV1`, baselines, and future migrations).
/// - Restore files to their original location.
/// - Conflict options (skip / overwrite / duplicate).
/// - Ready for future iCloud exports by selecting a root in an ubiquity container.
public enum MigrationBackupManager {

    // MARK: - Public types

    /// Policy when a backup already exists for a migration/store combination.
    public enum ConflictPolicy {
        /// Do nothing when a backup already exists for the migration and store.
        case skip
        /// Overwrite the existing backup in the same folder.
        case overwrite
        /// Create a new folder with an incrementing suffix (-1, -2, ...).
        case duplicate
    }

    /// A backup descriptor serialized to disk as JSON.
    public struct BackupDescriptor: Codable {
        /// Identifier of the migration that created this backup (for example, "MigrationV1").
        public let migrationID: String
        /// Optional human-readable label (for example, "before-merge").
        public let label: String?
        /// Full path of the original file or store.
        public let originalPath: String
        /// Backup creation date.
        public let createdAt: Date
        /// Names of files copied into the backup folder.
        public let files: [String]
    }

    // MARK: - Public API

    /// Backs up an SQLite store (main file plus optional -wal and -shm files).
    ///
    /// - Parameters:
    ///   - storeURL: URL of the original .sqlite file.
    ///   - migrationID: Migration ID (use `migration.id`).
    ///   - label: Optional label (for example, "pre-migration").
    ///   - conflictPolicy: Behavior when a backup already exists.
    ///   - rootOverride: Optional backup root, such as an App Group or iCloud folder.
    /// - Returns: The descriptor and backup-folder URL.
    @discardableResult
    public static func backupStore(
        at storeURL: URL,
        migrationID: String,
        label: String? = nil,
        conflictPolicy: ConflictPolicy = .duplicate,
        rootOverride: URL? = nil
    ) throws -> (descriptor: BackupDescriptor, folderURL: URL) {

        let fm = FileManager.default

        let storeDir = storeURL.deletingLastPathComponent()
        let storeName = storeDir.lastPathComponent

        // Backup root: the store directory's parent plus "migrationBackups" by default.
        let backupRoot = rootOverride ?? storeDir
            .deletingLastPathComponent()
            .appendingPathComponent("migrationBackups", isDirectory: true)

        // Base folder for this migration and store.
        let baseFolderName = "\(migrationID)_\(storeName)"
        let baseFolderURL = backupRoot.appendingPathComponent(baseFolderName, isDirectory: true)

        let (backupFolderURL, existingDescriptor) = try prepareBackupFolder(
            baseFolderURL: baseFolderURL,
            conflictPolicy: conflictPolicy,
            fileManager: fm
        )

        if let existingDescriptor {
            return (existingDescriptor, backupFolderURL)
        }

        // Ensure the folder exists.
        try fm.createDirectory(at: backupFolderURL, withIntermediateDirectories: true, attributes: nil)

        // File principali: .sqlite, .sqlite-wal, .sqlite-shm
        var copiedFiles: [String] = []

        func copyIfExists(_ url: URL) throws {
            guard fm.fileExists(atPath: url.path) else { return }
            let dest = backupFolderURL.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
            copiedFiles.append(url.lastPathComponent)
        }

        let basePath = storeURL.path
        let walURL = URL(fileURLWithPath: basePath + "-wal")
        let shmURL = URL(fileURLWithPath: basePath + "-shm")

        try copyIfExists(storeURL)
        try copyIfExists(walURL)
        try copyIfExists(shmURL)

        let descriptor = BackupDescriptor(
            migrationID: migrationID,
            label: label,
            originalPath: storeURL.path,
            createdAt: Date(),
            files: copiedFiles
        )

        try writeDescriptor(descriptor, in: backupFolderURL, fileManager: fm)

        logBackup(
            .info,
            event: "backup_store_created",
            message: "Store backup created",
            metadata: [
                "migrationID": migrationID,
                "folder": backupFolderURL.lastPathComponent,
                "files": String(copiedFiles.count)
            ]
        )
        return (descriptor, backupFolderURL)
    }

    /// Backs up a single file (for example, baseline.zip).
    ///
    /// - Parameters:
    ///   - fileURL: URL of the file to back up.
    ///   - migrationID: ID of the migration creating the backup.
    ///   - label: Optional label.
    ///   - conflictPolicy: Conflict policy.
    ///   - rootOverride: Optional backup root.
    @discardableResult
    public static func backupFile(
        at fileURL: URL,
        migrationID: String,
        label: String? = nil,
        conflictPolicy: ConflictPolicy = .duplicate,
        rootOverride: URL? = nil
    ) throws -> (descriptor: BackupDescriptor, folderURL: URL) {

        let fm = FileManager.default

        let fileDir = fileURL.deletingLastPathComponent()
        let fileName = fileURL.lastPathComponent

        let backupRoot = rootOverride ?? fileDir
            .deletingLastPathComponent()
            .appendingPathComponent("migrationBackups", isDirectory: true)

        let baseFolderName = "\(migrationID)_file_\(fileName)"
        let baseFolderURL = backupRoot.appendingPathComponent(baseFolderName, isDirectory: true)

        let (backupFolderURL, existingDescriptor) = try prepareBackupFolder(
            baseFolderURL: baseFolderURL,
            conflictPolicy: conflictPolicy,
            fileManager: fm
        )

        if let existingDescriptor {
            return (existingDescriptor, backupFolderURL)
        }

        try fm.createDirectory(at: backupFolderURL, withIntermediateDirectories: true, attributes: nil)

        let dest = backupFolderURL.appendingPathComponent(fileName)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: fileURL, to: dest)

        let descriptor = BackupDescriptor(
            migrationID: migrationID,
            label: label,
            originalPath: fileURL.path,
            createdAt: Date(),
            files: [fileName]
        )

        try writeDescriptor(descriptor, in: backupFolderURL, fileManager: fm)
        logBackup(
            .info,
            event: "backup_file_created",
            message: "File backup created",
            metadata: [
                "migrationID": migrationID,
                "folder": backupFolderURL.lastPathComponent,
                "file": fileName
            ]
        )
        return (descriptor, backupFolderURL)
    }

    /// Convenience API: backs up a store using `migration.id` as the identifier
    /// and `migration.backupRoot(for:)` as the default backup root.
    @discardableResult
    public static func backupStore(
        at storeURL: URL,
        configuration: GraphStoreConfiguration,
        migration: GraphMigration,
        label: String? = nil,
        conflictPolicy: ConflictPolicy = .duplicate
    ) throws -> (descriptor: BackupDescriptor, folderURL: URL) {
        let root = migration.backupRoot(for: configuration)
        return try backupStore(
            at: storeURL,
            migrationID: migration.id,
            label: label,
            conflictPolicy: conflictPolicy,
            rootOverride: root
        )
    }

    /// Convenience API: backs up a single file using `migration.id` as the identifier
    /// and `migration.backupRoot(for:)` as the default backup root.
    @discardableResult
    public static func backupFile(
        at fileURL: URL,
        configuration: GraphStoreConfiguration,
        migration: GraphMigration,
        label: String? = nil,
        conflictPolicy: ConflictPolicy = .duplicate
    ) throws -> (descriptor: BackupDescriptor, folderURL: URL) {
        let root = migration.backupRoot(for: configuration)
        return try backupFile(
            at: fileURL,
            migrationID: migration.id,
            label: label,
            conflictPolicy: conflictPolicy,
            rootOverride: root
        )
    }

    /// Finds all backups for a migration and store.
    ///
    /// - Parameters:
    ///   - migrationID: Migration ID.
    ///   - storeURL: URL of the original store.
    ///   - rootOverride: Backup root when different from the default.
    /// - Returns: `(descriptor, folderURL)` pairs ordered by creation date.
    public static func findBackupsForStore(
        migrationID: String,
        storeURL: URL,
        rootOverride: URL? = nil
    ) throws -> [(descriptor: BackupDescriptor, folderURL: URL)] {

        let fm = FileManager.default

        let storeDir = storeURL.deletingLastPathComponent()
        let storeName = storeDir.lastPathComponent
        let backupRoot = rootOverride ?? storeDir
            .deletingLastPathComponent()
            .appendingPathComponent("migrationBackups", isDirectory: true)

        let baseFolderName = "\(migrationID)_\(storeName)"

        guard fm.fileExists(atPath: backupRoot.path) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        var results: [(BackupDescriptor, URL)] = []

        for folder in contents where folder.hasDirectoryPath {
            guard folder.lastPathComponent.hasPrefix(baseFolderName) else { continue }
            let descriptorURL = folder.appendingPathComponent("backup-info.json")

            guard fm.fileExists(atPath: descriptorURL.path) else { continue }
            do {
                let data = try Data(contentsOf: descriptorURL)
                let descriptor = try JSONDecoder().decode(BackupDescriptor.self, from: data)

                // Verify that originalPath matches the supplied store.
                if descriptor.originalPath == storeURL.path && descriptor.migrationID == migrationID {
                    results.append((descriptor, folder))
                }
            } catch {
                logBackup(
                    .warning,
                    event: "backup_descriptor_read_failed",
                    message: error.localizedDescription,
                    metadata: ["descriptor": descriptorURL.lastPathComponent]
                )
            }
        }

        // Sort by createdAt, oldest first.
        results.sort { $0.0.createdAt < $1.0.createdAt }
        return results
    }

    /// Restores a backup to its original location.
    ///
    /// - Parameters:
    ///   - descriptor: Backup descriptor, usually returned by `backupStore` or `findBackupsForStore`.
    ///   - folderURL: Folder containing the backup and its `backup-info.json`.
    ///   - overwriteExisting: When true, remove current files before copying.
    public static func restoreToOriginalLocation(
        descriptor: BackupDescriptor,
        from folderURL: URL,
        overwriteExisting: Bool = true
    ) throws {
        let fm = FileManager.default
        let originalURL = URL(fileURLWithPath: descriptor.originalPath)
        let originalDir = originalURL.deletingLastPathComponent()

        // Ensure the folder exists.
        if !fm.fileExists(atPath: originalDir.path) {
            try fm.createDirectory(at: originalDir, withIntermediateDirectories: true, attributes: nil)
        }

        for fileName in descriptor.files {
            let src = folderURL.appendingPathComponent(fileName)
            let dest = originalDir.appendingPathComponent(fileName)

            guard fm.fileExists(atPath: src.path) else {
                logBackup(
                    .warning,
                    event: "backup_file_missing",
                    message: "Backup file is missing",
                    metadata: ["file": src.lastPathComponent]
                )
                continue
            }

            if fm.fileExists(atPath: dest.path) {
                if overwriteExisting {
                    try fm.removeItem(at: dest)
                } else {
                    logBackup(
                        .info,
                        event: "backup_restore_file_skipped",
                        message: "Restore skipped because destination already exists",
                        metadata: ["file": dest.lastPathComponent]
                    )
                    continue
                }
            }
            try fm.copyItem(at: src, to: dest)
        }

        logBackup(
            .info,
            event: "backup_restore_completed",
            message: "Backup restore completed",
            metadata: ["folder": originalDir.lastPathComponent]
        )
    }

    // MARK: - Private helpers

    private static func prepareBackupFolder(
        baseFolderURL: URL,
        conflictPolicy: ConflictPolicy,
        fileManager fm: FileManager
    ) throws -> (folderURL: URL, existingDescriptor: BackupDescriptor?) {
        // Optimize .skip by reusing an existing descriptor when possible.
        if conflictPolicy == .skip, fm.fileExists(atPath: baseFolderURL.path) {
            do {
                let existingDescriptor = try loadDescriptor(in: baseFolderURL, fileManager: fm)
                logBackup(
                    .info,
                    event: "backup_existing_reused",
                    message: "Existing backup reused",
                    metadata: ["folder": baseFolderURL.lastPathComponent]
                )
                return (baseFolderURL, existingDescriptor)
            } catch {
                logBackup(
                    .warning,
                    event: "backup_existing_descriptor_read_failed",
                    message: error.localizedDescription,
                    metadata: ["folder": baseFolderURL.lastPathComponent]
                )
                // If the descriptor cannot be read, proceed as if it did not exist.
            }
        }

        // For all other cases, or when skip fails, ask `resolveBackupFolder`
        // for the correct folder.
        let folderURL = try resolveBackupFolder(
            baseFolderURL: baseFolderURL,
            conflictPolicy: conflictPolicy,
            fileManager: fm
        )
        return (folderURL, nil)
    }

    private static func resolveBackupFolder(
        baseFolderURL: URL,
        conflictPolicy: ConflictPolicy,
        fileManager fm: FileManager
    ) throws -> URL {
        switch conflictPolicy {
        case .overwrite:
            // Use the base folder, clearing it when necessary.
            if fm.fileExists(atPath: baseFolderURL.path) {
                try fm.removeItem(at: baseFolderURL)
            }
            return baseFolderURL

        case .skip:
            // The .skip policy is handled by the caller.
            // Here we only resolve the folder for new backups.
            return baseFolderURL

        case .duplicate:
            if !fm.fileExists(atPath: baseFolderURL.path) {
                return baseFolderURL
            }
            // Trova un suffisso libero: base, base-1, base-2, ...
            var index = 1
            while true {
                let candidate = baseFolderURL.deletingLastPathComponent()
                    .appendingPathComponent(baseFolderURL.lastPathComponent + "-\(index)", isDirectory: true)
                if !fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                index += 1
            }
        }
    }

    private static func writeDescriptor(
        _ descriptor: BackupDescriptor,
        in folderURL: URL,
        fileManager fm: FileManager
    ) throws {
        let metaURL = folderURL.appendingPathComponent("backup-info.json")
        let data = try JSONEncoder().encode(descriptor)
        if fm.fileExists(atPath: metaURL.path) {
            try fm.removeItem(at: metaURL)
        }
        try data.write(to: metaURL, options: .atomic)
    }

    private static func loadDescriptor(
        in folderURL: URL,
        fileManager fm: FileManager
    ) throws -> BackupDescriptor {
        let metaURL = folderURL.appendingPathComponent("backup-info.json")
        let data = try Data(contentsOf: metaURL)
        let descriptor = try JSONDecoder().decode(BackupDescriptor.self, from: data)
        return descriptor
    }

    private static func logBackup(
        _ level: GraphMigrationLogLevel,
        event: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        GraphMigrationLogger.log(
            migrationID: "MigrationBackupManager",
            level: level,
            event: event,
            message: message,
            metadata: metadata
        )
    }
}
