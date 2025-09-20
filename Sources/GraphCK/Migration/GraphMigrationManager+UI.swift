//
//  GraphMigrationManager+UI.swift
//  GraphCK
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
    
    /*
    Esempio di utilizzo di observeMigrationProgress:

    // Registrazione dell'observer
    let observer = GraphMigrationManager.observeMigrationProgress { progressInfo in
        print("Migrazione avanzata: \(progressInfo.progress * 100)% - \(progressInfo.stepDescription)")
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
