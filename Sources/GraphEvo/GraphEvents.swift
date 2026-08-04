//
//  GraphEvents.swift
//  GraphEvo
//
//  Public diagnostics contract for applications embedding GraphEvo.
//

import Foundation

/// The persistence mode currently used by a Graph instance.
public enum GraphPersistenceMode {
    case local
    case cloud
    case localFallback
}

/// State changes emitted by GraphEvo.
public enum GraphState {
    case readiness(GraphReadiness)
    case cloudStatus(GraphCloudStatus)
    case persistenceMode(GraphPersistenceMode)
}

/// Recoverable conditions that the application may want to surface or log.
public enum GraphWarning: LocalizedError {
    case cloudStoreFallback(underlying: Error)
    case metadataPersistence(underlying: Error)
    case persistentHistoryTokenStore(underlying: Error)
    case persistentHistoryMissingTransactionAuthor

    public var errorDescription: String? {
        switch self {
        case .cloudStoreFallback(let error):
            return "CloudKit store unavailable; GraphEvo fell back to local persistence: \(error.localizedDescription)"
        case .metadataPersistence(let error):
            return "GraphEvo could not read or write store metadata: \(error.localizedDescription)"
        case .persistentHistoryTokenStore(let error):
            return "GraphEvo could not persist the Persistent History token: \(error.localizedDescription)"
        case .persistentHistoryMissingTransactionAuthor:
            return "GraphEvo received a Persistent History transaction without an author; local-change filtering may be incomplete."
        }
    }
}

/// Non-recoverable or operation-level failures emitted by GraphEvo.
///
/// A migration failure is intentionally reported here, separately from
/// `GraphReadiness`: the store may still be open and usable even when an
/// application-defined migration did not complete.
public enum GraphFailure: LocalizedError {
    case storeOpening(GraphStoreOpeningError)
    case migration(migrationID: String, phase: String, underlying: Error)
    case persistentHistory(underlying: Error)
    case query(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .storeOpening(let error):
            return error.localizedDescription
        case .migration(let migrationID, let phase, let error):
            return "Migration '\(migrationID)' failed during \(phase): \(error.localizedDescription)"
        case .persistentHistory(let error):
            return "Persistent History processing failed: \(error.localizedDescription)"
        case .query(let error):
            return "Graph query failed: \(error.localizedDescription)"
        }
    }
}

/// A diagnostic event emitted by GraphEvo for the application to handle.
public enum GraphEvent {
    case stateChanged(GraphState)
    case warning(GraphWarning)
    case error(GraphFailure)
}

/// Receives GraphEvo state, warning and error events.
public protocol GraphEventDelegate: AnyObject {
    func graph(_ graph: Graph, didReceive event: GraphEvent)
}
