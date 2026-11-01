import Foundation

/// Refusals occur before any application record is removed.
public enum GraphRemovalError: Error, Equatable {
    case invalidLimit
    case recordLimitExceeded
}

extension GraphStore {
    /// Removes this graph's application records and owned attachments in one local transaction.
    /// Graph identity and control/sync metadata are preserved. The return value counts logical
    /// records, including attachments. Cloud delivery remains asynchronous and independently receipted.
    /// The limit bounds selected records, not total inventory, payload memory, SQL I/O or cloud work.
    @discardableResult
    public func removeAll(maximumRecords: Int = 10_000) async throws -> Int {
        guard maximumRecords > 0 else { throw GraphRemovalError.invalidLimit }
        return try await transaction { try $0.removeAll(maximumRecords: maximumRecords) }
    }
}

extension GraphMutation {
    /// Empties this graph within the enclosing transaction; later edits can repopulate it.
    /// The transaction owns rollback, cancellation and its single native save.
    @discardableResult
    public func removeAll(maximumRecords: Int = 10_000) throws -> Int {
        guard maximumRecords > 0 else { throw GraphRemovalError.invalidLimit }
        return try withContext { context, adapter in
            guard let remove = adapter.removeAll else { throw GraphStoreError.unsupportedLayout }
            return try remove(context, graphID, maximumRecords)
        }
    }
}
