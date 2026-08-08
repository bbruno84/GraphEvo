//
//  GraphMigrationManager+UI.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation

extension Notification.Name {
    /// Notification emitted as a migration advances.
    public static let GraphMigrationProgressDidChange = Notification.Name("GraphMigrationProgressDidChange")
    
    
}

extension GraphMigrationManager {
    /// Standardized userInfo keys for progress notifications.
    public enum ProgressKey: String {
        case storeURL
        case phase
        case progress
        case stepDescription
        case status
    }

    /// Represents a migration progress event.
    public struct ProgressInfo {
        public let storeURL: URL
        public let phase: GraphLifecyclePhase
        public let progress: Double
        public let stepDescription: String
        public let status: String
    }

    /// Standardized userInfo keys for failure notifications.
    public enum FailureKey: String {
        case migrationID
        case phase
        case storeURL
        case graphID
        case error
        case errorDescription
    }

    /// Represents a migration error emitted by the lifecycle manager.
    public struct FailureInfo {
        public let migrationID: String
        public let phase: GraphLifecyclePhase
        public let storeURL: URL?
        public let graphID: String
        public let error: Error
        public let errorDescription: String
    }

    /// Parser sicuro da Notification → ProgressInfo.
    public static func parseProgress(from notification: Notification) -> ProgressInfo? {
        guard notification.name == .GraphMigrationProgressDidChange,
              let userInfo = notification.userInfo,
              let storeURL = userInfo[ProgressKey.storeURL.rawValue] as? URL,
              let phase = userInfo[ProgressKey.phase.rawValue] as? GraphLifecyclePhase,
              let progress = userInfo[ProgressKey.progress.rawValue] as? Double,
              let stepDescription = userInfo[ProgressKey.stepDescription.rawValue] as? String,
              let status = userInfo[ProgressKey.status.rawValue] as? String else {
            return nil
        }

        return ProgressInfo(
            storeURL: storeURL,
            phase: phase,
            progress: progress,
            stepDescription: stepDescription,
            status: status
        )
    }

    /// Parser sicuro da Notification → FailureInfo.
    public static func parseFailure(from notification: Notification) -> FailureInfo? {
        guard notification.name == .graphMigrationDidFail,
              let userInfo = notification.userInfo,
              let migrationID = userInfo[FailureKey.migrationID.rawValue] as? String,
              let phase = userInfo[FailureKey.phase.rawValue] as? GraphLifecyclePhase,
              let graphID = userInfo[FailureKey.graphID.rawValue] as? String,
              let error = userInfo[FailureKey.error.rawValue] as? Error,
              let errorDescription = userInfo[FailureKey.errorDescription.rawValue] as? String else {
            return nil
        }

        return FailureInfo(
            migrationID: migrationID,
            phase: phase,
            storeURL: userInfo[FailureKey.storeURL.rawValue] as? URL,
            graphID: graphID,
            error: error,
            errorDescription: errorDescription
        )
    }
    
    /// Manually posts a migration progress notification.
    /// - Parameters:
    ///   - storeURL: L'URL dello store migrato.
    ///   - phase: The migration phase.
    ///   - progress: Progress value (0.0 - 1.0).
    ///   - stepDescription: Descrizione dello step corrente.
    ///   - status: The current migration status.
    public static func postMigrationProgress(
        storeURL: URL,
        phase: GraphLifecyclePhase,
        progress: Double,
        stepDescription: String,
        status: String
    ) {
        let userInfo: [String: Any] = [
            ProgressKey.storeURL.rawValue: storeURL,
            ProgressKey.phase.rawValue: phase,
            ProgressKey.progress.rawValue: progress,
            ProgressKey.stepDescription.rawValue: stepDescription,
            ProgressKey.status.rawValue: status
        ]
        NotificationCenter.default.post(name: .GraphMigrationProgressDidChange, object: nil, userInfo: userInfo)
    }

    /*
    Esempio di utilizzo di postMigrationProgress:

    // Manually post a migration progress notification.
    GraphMigrationManager.postMigrationProgress(
        storeURL: URL(fileURLWithPath: "/path/to/store.sqlite"),
        phase: .preparing,
        progress: 0.2,
        stepDescription: "Migration preparation",
        status: "In progress"
    )
    */
    
    /// Adds an observer for migration progress notifications.
    /// - Parameter handler: Closure called with the decoded ProgressInfo event.
    /// - Returns: Observer token to use for removal.
    public static func observeMigrationProgress(using handler: @escaping (ProgressInfo) -> Void) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(forName: .GraphMigrationProgressDidChange, object: nil, queue: .main) { notification in
            if let progressInfo = parseProgress(from: notification) {
                handler(progressInfo)
            }
        }
    }

    /// Adds an observer for migration failure notifications.
    /// - Parameter handler: Closure called with the decoded FailureInfo event.
    /// - Returns: Observer token to use for removal.
    public static func observeMigrationFailure(using handler: @escaping (FailureInfo) -> Void) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(forName: .graphMigrationDidFail, object: nil, queue: .main) { notification in
            if let failureInfo = parseFailure(from: notification) {
                handler(failureInfo)
            }
        }
    }
    
    /*
    Esempio di utilizzo di observeMigrationProgress:

    // Registrazione dell'observer
    let observer = GraphMigrationManager.observeMigrationProgress { progressInfo in
        // Progress is delivered through the notification; the application
        // decides whether and where to log it.
    }

    // Remove the observer when it is no longer needed.
    GraphMigrationManager.removeProgressObserver(observer)
    */
    
    /// Removes a previously added observer.
    /// - Parameter observer: The observer token to remove.
    public static func removeProgressObserver(_ observer: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(observer)
    }
}
