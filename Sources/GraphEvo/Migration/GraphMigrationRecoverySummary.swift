import Foundation

/// Historical outcome of the latest application-confirmed recovery publication.
/// This is not a live count and does not change migration execution state.
public struct GraphMigrationRecoverySummary: Codable, Equatable, Sendable {
    public let recoveryID: String
    public let completedAt: Date
    public let recordsRequiringManualReview: Int
    public var requiresManualReview: Bool { recordsRequiringManualReview > 0 }
}

/// Value-only notification payload, scoped to one local store and migration.
public struct GraphMigrationRecoverySummaryChange: Sendable {
    public let storeScope: String
    public let migrationID: String
    public let version: Int
    public let summary: GraphMigrationRecoverySummary
}

public extension Notification.Name {
    /// Posted asynchronously on the main queue after a changed summary is saved.
    /// `object` is a `GraphMigrationRecoverySummaryChange`. Read the API on launch;
    /// notifications are transient and are not a substitute for persisted state.
    static let graphMigrationRecoverySummaryDidChange = Notification.Name("GraphEvo.migration.recoverySummaryDidChange")
}
