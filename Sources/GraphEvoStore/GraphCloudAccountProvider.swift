import CloudKit
import Foundation

enum GraphCloudAccountAvailability: Sendable, Equatable {
    case available(String), temporarilyUnavailable, signedOut, restricted
    static func live(_ identifier: String) async throws -> Self {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { throw GraphCloudError.invalidConfiguration }
        return try await read(from: CKContainer(identifier: identifier))
    }
    static func read(from container: CKContainer) async throws -> Self {
        do {
            switch try await container.accountStatus() {
            case .available: return .available(try await container.userRecordID().recordName)
            case .noAccount: return .signedOut
            case .restricted: return .restricted
            case .couldNotDetermine, .temporarilyUnavailable: return .temporarilyUnavailable
            @unknown default: return .restricted
            }
        } catch let error as CKError {
            switch error.code {
            case .networkFailure, .networkUnavailable, .accountTemporarilyUnavailable, .notAuthenticated:
                return .temporarilyUnavailable
            default: throw error
            }
        }
    }
}

/// NotificationCenter owns its token; only token installation/removal needs this lock.
final class GraphCloudAccountObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    init(name: Notification.Name = .CKAccountChanged, changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in changed() }
    }
    func cancel() {
        let value = lock.withLock { let value = token; token = nil; return value }
        if let value { NotificationCenter.default.removeObserver(value) }
    }
    deinit { cancel() }
}

enum GraphCloudSessionAccountSignal: Sendable { case signedOut, differentAccount, signedIn, temporarilyUnavailable, restricted }

extension GraphCloudAdapter {
    func readAccountAvailability(_ identifier: String) async throws -> GraphCloudAccountAvailability {
        do {
            if let accountAvailability { return try await accountAvailability(identifier) }
            let value = try await account(identifier)
            guard !value.isEmpty else { throw GraphCloudError.accountUnavailable }
            return .available(value)
        } catch GraphCloudError.accountUnavailable { return .temporarilyUnavailable }
    }
}
