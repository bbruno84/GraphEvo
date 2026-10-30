import CoreData
import Foundation

/// MC01: closed, disposable S02 stores only. No public opener, ownership fence or activation API.
/// The host must close every lease/process before calling these filesystem operations.
enum GraphStoreCopyLaboratory {
    enum Failure: Error, Equatable, Sendable { case fixture, destinationExists, incompatible, history }
    enum Method: String, Codable, CaseIterable, Sendable { case coreData, directory }
    struct History: Equatable, Codable, Sendable {
        let storeID: String
        let transactions: Int
        let changes: Int
        let inserts: Int
        let updates: Int
        let deletes: Int
        let lastToken: Data?
    }

    static func metadata(at url: URL) throws -> [String: Any] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        guard metadata[NSStoreModelVersionIdentifiersKey] as? [String] == [GraphRuntimeSchema.nativeModelIdentifier],
              GraphRuntimeSchema.makeNativeModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
            throw Failure.incompatible
        }
        return metadata
    }

    /// Both paths preserve opaque artifacts; neither parses private SQLite or mirroring tables.
    static func copyClosed(from source: URL, to destination: URL, method: Method) throws {
        guard source.isFileURL, destination.isFileURL,
              source.pathExtension == "sqlite", destination.pathExtension == "sqlite",
              source.lastPathComponent == destination.lastPathComponent,
              source.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() != destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() else { throw Failure.fixture }
        guard !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else { throw Failure.destinationExists }
        _ = try metadata(at: source)
        switch method {
        case .directory:
            try FileManager.default.copyItem(at: source.deletingLastPathComponent(), to: destination.deletingLastPathComponent())
        case .coreData:
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replaceClosed(from: source, at: destination)
        }
        _ = try metadata(at: destination)
    }

    static func replaceClosed(from source: URL, at destination: URL) throws {
        guard source.isFileURL, destination.isFileURL,
              source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw Failure.fixture }
        _ = try metadata(at: source)
        GraphValueTransformer.register()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: GraphRuntimeSchema.makeNativeModel())
        let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true,
                                          NSMigratePersistentStoresAutomaticallyOption: false]
        try coordinator.replacePersistentStore(at: destination, destinationOptions: options,
            withPersistentStoreFrom: source, sourceOptions: options, ofType: NSSQLiteStoreType)
    }

    /// Public history API, used only after all native owners are closed.
    static func history(at url: URL, after tokenData: Data? = nil) throws -> History {
        _ = try metadata(at: url)
        GraphValueTransformer.register()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: GraphRuntimeSchema.makeNativeModel())
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let result: History
        do {
            result = try context.performAndWait {
                let token = try tokenData.map { bytes -> NSPersistentHistoryToken in
                    guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: bytes) else { throw Failure.history }
                    return value
                }
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                request.resultType = .transactionsAndChanges
                guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction] else { throw Failure.history }
                let changes = transactions.flatMap { $0.changes ?? [] }
                let last = try transactions.last.map { try NSKeyedArchiver.archivedData(withRootObject: $0.token, requiringSecureCoding: true) }
                return History(storeID: store.identifier, transactions: transactions.count, changes: changes.count,
                    inserts: changes.filter { $0.changeType == .insert }.count,
                    updates: changes.filter { $0.changeType == .update }.count,
                    deletes: changes.filter { $0.changeType == .delete }.count, lastToken: last)
            }
        } catch {
            context.performAndWait { context.reset() }
            try coordinator.remove(store)
            throw error
        }
        context.performAndWait { context.reset() }
        try coordinator.remove(store)
        return result
    }
}
