import Foundation

/// Local graph configuration, not consumer data and not a CloudKit setting.
package enum GraphConflictPolicy: String, Codable, Sendable {
    case cloudWins, lastEditWins

    package func prefersLocal(local: Date?, remote: Date?) -> Bool {
        guard self == .lastEditWins, let local else { return false }
        guard let remote else { return true }
        return local > remote
    }
}
