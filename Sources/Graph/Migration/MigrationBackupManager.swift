//
//  MigrationBackupManager.swift
//  Graph
//
//  Created by Valerio Buriani on 07/11/25.
//


import Foundation

/// Gestisce backup e ripristino dei file usati dalle migrazioni
/// (store SQLite + WAL/SHM, baseline.zip, ecc).
///
/// Obiettivi:
/// - API unica riutilizzabile da tutte le migrazioni (`MigrationV1`, baseline, future)
/// - Possibilità di ripristinare i file nella loro posizione originale
/// - Opzioni di conflitto (skip / overwrite / duplicate)
/// - Design pronto per futuri export su iCloud (basta scegliere un root in un container ubiquity)
public enum MigrationBackupManager {

    // MARK: - Tipi pubblici

    /// Policy quando esiste già un backup per quella combinazione (migrazione + store).
    public enum ConflictPolicy {
        /// Se esiste già un backup per quella migrazione + store, non fare nulla.
        case skip
        /// Sovrascrivi il backup esistente (stessa cartella).
        case overwrite
        /// Crea una nuova cartella con suffisso incrementale (-1, -2, …).
        case duplicate
    }

    /// Descrittore di un backup (serializzato su disco come JSON).
    public struct BackupDescriptor: Codable {
        /// Identificatore della migrazione che ha creato questo backup (es. "MigrationV1").
        public let migrationID: String
        /// Facoltativo: label umana (es. "before-merge", "pre-baseline").
        public let label: String?
        /// Percorso completo del file (o dello store) originale.
        public let originalPath: String
        /// Data/ora di creazione del backup.
        public let createdAt: Date
        /// Lista dei nomi dei file copiati all’interno della cartella di backup.
        public let files: [String]
    }

    // MARK: - API pubblica

    /// Esegue il backup di uno store SQLite (file principale + -wal + -shm).
    ///
    /// - Parameters:
    ///   - storeURL: URL del file .sqlite originale.
    ///   - migrationID: ID della migrazione (usa `migration.id`).
    ///   - label: Etichetta facoltativa (es. "pre-migration").
    ///   - conflictPolicy: Come comportarsi se esiste già un backup per questa combinazione.
    ///   - rootOverride: Root opzionale per i backup (es. una cartella in AppGroup o in iCloud).
    /// - Returns: Descriptor + URL della cartella di backup.
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

        // Root per i backup: di default padre della directory dello store + "migrationBackups".
        let backupRoot = rootOverride ?? storeDir
            .deletingLastPathComponent()
            .appendingPathComponent("migrationBackups", isDirectory: true)

        // Cartella base per questa migrazione + store.
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

        // Assicurati che la cartella esista
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

        print("[MigrationBackupManager] 💾 Store backup creato in \(backupFolderURL.path)")
        return (descriptor, backupFolderURL)
    }

    /// Esegue il backup di un singolo file (es. baseline.zip).
    ///
    /// - Parameters:
    ///   - fileURL: URL del file da salvare.
    ///   - migrationID: ID della migrazione che effettua il backup.
    ///   - label: Etichetta facoltativa.
    ///   - conflictPolicy: Policy di conflitto.
    ///   - rootOverride: Root opzionale per i backup.
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
        print("[MigrationBackupManager] 💾 File backup creato in \(backupFolderURL.path)")
        return (descriptor, backupFolderURL)
    }

    /// Convenience API: esegue il backup di uno store usando:
    ///  - `migration.id` come identificatore
    ///  - `migration.backupRoot(for:)` come root di default per i backup
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

    /// Convenience API: esegue il backup di un singolo file usando:
    ///  - `migration.id` come identificatore
    ///  - `migration.backupRoot(for:)` come root di default per i backup
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

    /// Trova tutti i backup per una certa migrazione + store.
    ///
    /// - Parameters:
    ///   - migrationID: ID della migrazione.
    ///   - storeURL: URL dello store originale.
    ///   - rootOverride: root dei backup (se differente dal default).
    /// - Returns: Lista di (descriptor, folderURL) ordinati per data di creazione.
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

                // Verifichiamo che l'originalPath corrisponda allo store passato.
                if descriptor.originalPath == storeURL.path && descriptor.migrationID == migrationID {
                    results.append((descriptor, folder))
                }
            } catch {
                print("[MigrationBackupManager] ⚠️ Impossibile leggere descriptor in \(descriptorURL.path): \(error)")
            }
        }

        // Ordina per createdAt, dal più vecchio al più recente
        results.sort { $0.0.createdAt < $1.0.createdAt }
        return results
    }

    /// Ripristina un backup nella posizione originale.
    ///
    /// - Parameters:
    ///   - descriptor: Il descriptor del backup (tipicamente ottenuto da `backupStore` o `findBackupsForStore`).
    ///   - folderURL: Cartella che contiene il backup e il relativo `backup-info.json`.
    ///   - overwriteExisting: Se true, rimuove eventuali file correnti prima di copiare.
    public static func restoreToOriginalLocation(
        descriptor: BackupDescriptor,
        from folderURL: URL,
        overwriteExisting: Bool = true
    ) throws {
        let fm = FileManager.default
        let originalURL = URL(fileURLWithPath: descriptor.originalPath)
        let originalDir = originalURL.deletingLastPathComponent()

        // Assicuriamoci che la cartella esista
        if !fm.fileExists(atPath: originalDir.path) {
            try fm.createDirectory(at: originalDir, withIntermediateDirectories: true, attributes: nil)
        }

        for fileName in descriptor.files {
            let src = folderURL.appendingPathComponent(fileName)
            let dest = originalDir.appendingPathComponent(fileName)

            guard fm.fileExists(atPath: src.path) else {
                print("[MigrationBackupManager] ⚠️ File di backup mancante: \(src.path)")
                continue
            }

            if fm.fileExists(atPath: dest.path) {
                if overwriteExisting {
                    try fm.removeItem(at: dest)
                } else {
                    print("[MigrationBackupManager] ⏭ Skip \(dest.lastPathComponent), esiste già e overwrite=false")
                    continue
                }
            }
            try fm.copyItem(at: src, to: dest)
        }

        print("[MigrationBackupManager] 🔄 Ripristino completato verso \(originalDir.path)")
    }

    // MARK: - Helpers privati

    private static func prepareBackupFolder(
        baseFolderURL: URL,
        conflictPolicy: ConflictPolicy,
        fileManager fm: FileManager
    ) throws -> (folderURL: URL, existingDescriptor: BackupDescriptor?) {
        // Gestione ottimizzata della policy .skip con eventuale riutilizzo del descriptor esistente
        if conflictPolicy == .skip, fm.fileExists(atPath: baseFolderURL.path) {
            do {
                let existingDescriptor = try loadDescriptor(in: baseFolderURL, fileManager: fm)
                print("[MigrationBackupManager] ⚠️ Backup esistente trovato in \(baseFolderURL.path), riutilizzo backup esistente.")
                return (baseFolderURL, existingDescriptor)
            } catch {
                print("[MigrationBackupManager] ⚠️ Impossibile leggere descriptor esistente in \(baseFolderURL.path): \(error). Procedo con la creazione di un nuovo backup.")
                // Se non riusciamo a leggere il descriptor, procediamo come se non esistesse
            }
        }

        // Per tutti gli altri casi, o se lo skip non è andato a buon fine,
        // demandiamo a `resolveBackupFolder` per ottenere la cartella corretta.
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
            // Usiamo la cartella base, eventualmente svuotandola.
            if fm.fileExists(atPath: baseFolderURL.path) {
                try fm.removeItem(at: baseFolderURL)
            }
            return baseFolderURL

        case .skip:
            // La policy .skip viene gestita a livello superiore (chiamante).
            // Qui risolviamo solo la cartella da usare per nuovi backup.
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
}
