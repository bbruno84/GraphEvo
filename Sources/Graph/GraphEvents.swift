//
//  GraphEvents.swift
//  GraphCK
//
//  Public diagnostics contract for applications embedding GraphCK.
//

import Foundation

/// The persistence mode currently used by a Graph instance.
public enum GraphPersistenceMode {
    case local
    case cloud
    case localFallback
}

/// State changes emitted by GraphCK.
public enum GraphState {
    case readiness(GraphReadiness)
    case cloudStatus(GraphCloudStatus)
    case persistenceMode(GraphPersistenceMode)
}

/// Recoverable conditions that the application may want to surface or log.
public enum GraphWarning: LocalizedError {
    case cloudStoreFallback(underlying: Error)
    case metadataPersistence(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .cloudStoreFallback(let error):
            return "CloudKit store unavailable; GraphCK fell back to local persistence: \(error.localizedDescription)"
        case .metadataPersistence(let error):
            return "GraphCK could not read or write store metadata: \(error.localizedDescription)"
        }
    }
}

/// Non-recoverable or operation-level failures emitted by GraphCK.
public enum GraphFailure: LocalizedError {
    case storeOpening(GraphStoreOpeningError)
    case migration(migrationID: String, phase: String, underlying: Error)
    case persistentHistory(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .storeOpening(let error):
            return error.localizedDescription
        case .migration(let migrationID, let phase, let error):
            return "Migration '\(migrationID)' failed during \(phase): \(error.localizedDescription)"
        case .persistentHistory(let error):
            return "Persistent History processing failed: \(error.localizedDescription)"
        }
    }
}

/// A diagnostic event emitted by GraphCK for the application to handle.
public enum GraphEvent {
    case stateChanged(GraphState)
    case warning(GraphWarning)
    case error(GraphFailure)
}

/// Receives GraphCK state, warning and error events.
public protocol GraphEventDelegate: AnyObject {
    func graph(_ graph: Graph, didReceive event: GraphEvent)
}
