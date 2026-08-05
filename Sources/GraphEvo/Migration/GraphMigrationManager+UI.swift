//
//  GraphMigrationManager+UI.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation

extension Notification.Name {
    /// Notifica emessa quando avanza una migrazione.
    public static let GraphMigrationProgressDidChange = Notification.Name("GraphMigrationProgressDidChange")
    
    
}

extension GraphMigrationManager {
    /// Chiavi standardizzate per userInfo della notifica di progress.
    public enum ProgressKey: String {
        case storeURL
        case phase
        case progress
        case stepDescription
        case status
    }

    /// Rappresenta un evento di progress di migrazione.
    public struct ProgressInfo {
        public let storeURL: URL
        public let phase: GraphLifecyclePhase
        public let progress: Double
        public let stepDescription: String
        public let status: String
    }

    /// Chiavi standardizzate per userInfo della notifica di failure.
    public enum FailureKey: String {
        case migrationID
        case phase
        case storeURL
        case graphID
        case error
        case errorDescription
    }

    /// Rappresenta un errore di migrazione emesso dal lifecycle manager.
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
    
    /// Invia manualmente una notifica di avanzamento migrazione.
    /// - Parameters:
    ///   - storeURL: L'URL dello store migrato.
    ///   - phase: La fase della migrazione.
    ///   - progress: Valore di avanzamento (0.0 - 1.0).
    ///   - stepDescription: Descrizione dello step corrente.
    ///   - status: Stato corrente della migrazione.
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

    // Invio manuale di una notifica di avanzamento migrazione
    GraphMigrationManager.postMigrationProgress(
        storeURL: URL(fileURLWithPath: "/percorso/al/store.sqlite"),
        phase: .preparing,
        progress: 0.2,
        stepDescription: "Preparazione della migrazione",
        status: "In corso"
    )
    */
    
    /// Aggiunge un observer per le notifiche di progresso di migrazione.
    /// - Parameter handler: Closure chiamata con l'evento ProgressInfo decodificato.
    /// - Returns: Il token observer da utilizzare per la rimozione.
    public static func observeMigrationProgress(using handler: @escaping (ProgressInfo) -> Void) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(forName: .GraphMigrationProgressDidChange, object: nil, queue: .main) { notification in
            if let progressInfo = parseProgress(from: notification) {
                handler(progressInfo)
            }
        }
    }

    /// Aggiunge un observer per le notifiche di fallimento migrazione.
    /// - Parameter handler: Closure chiamata con l'evento FailureInfo decodificato.
    /// - Returns: Il token observer da utilizzare per la rimozione.
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

    // Quando non serve più, rimuovere l'observer
    GraphMigrationManager.removeProgressObserver(observer)
    */
    
    /// Rimuove un observer precedentemente aggiunto.
    /// - Parameter observer: Il token observer da rimuovere.
    public static func removeProgressObserver(_ observer: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(observer)
    }
}
