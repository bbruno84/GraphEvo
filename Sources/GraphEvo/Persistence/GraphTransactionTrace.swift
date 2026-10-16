import CoreData
import Foundation

/// Opt-in transaction evidence. No payloads, managed objects or generation-token bytes.
public struct GraphTransactionTrace: Codable {
    public enum Phase: String, Codable { case outcome, history }
    public enum Outcome: String, Codable { case succeeded, failed }
    public enum Stage: String, Codable {
        case begin, pinned, bodyEnd, precommitCompare, saveResult, rollbackResult, finished
    }
    public struct Checkpoint: Codable {
        public let stage: Stage
        public let elapsed: TimeInterval
        public let inserted: Int?
        public let updated: Int?
        public let deleted: Int?
        public let generationsEqual: Bool?
    }
    public struct History: Codable {
        public enum Status: String, Codable { case available, unavailable }
        public struct Group: Codable {
            public let author: String?
            public let entityName: String
            public let operation: String
            public let count: Int
        }
        public let status: Status
        /// The requested wall-clock interval, not an atomic generation/history boundary.
        public let from: Date
        public let through: Date
        public let observedChanges: Int
        public let groups: [Group]
        public let truncated: Bool
        /// Always false: retention and non-domain bookkeeping cannot be certified by this read.
        public let isExhaustive: Bool
        public let errorDomain: String?
        public let errorCode: Int?
    }
    public let diagnosticID: UUID
    public let phase: Phase
    public let startedAt: Date
    public let finishedAt: Date
    public let outcome: Outcome
    /// True once the private context save succeeded, even if later merging failed.
    public let didSave: Bool
    public let checkpoints: [Checkpoint]
    public let errorDomain: String?
    public let errorCode: Int?
    public let history: History?
}

internal final class GraphTransactionTraceRecorder {
    let id: UUID
    let startedAt = Date()
    private let start = DispatchTime.now().uptimeNanoseconds
    var coordinator: NSPersistentStoreCoordinator?
    var didSave = false
    private var checkpoints: [GraphTransactionTrace.Checkpoint] = []

    init(id: UUID) {
        self.id = id
        record(.begin)
    }

    /// Called sequentially; context counts are only read on that context's queue.
    func record(_ stage: GraphTransactionTrace.Stage, context: NSManagedObjectContext? = nil,
                generationsEqual: Bool? = nil) {
        checkpoints.append(.init(stage: stage,
            elapsed: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000,
            inserted: context?.insertedObjects.count, updated: context?.updatedObjects.count,
            deleted: context?.deletedObjects.count, generationsEqual: generationsEqual))
    }

    func finish(graph: Graph, error: Error?) {
        record(.finished)
        let failure = error as NSError?
        let trace = GraphTransactionTrace(diagnosticID: id, phase: .outcome,
            startedAt: startedAt, finishedAt: Date(), outcome: error == nil ? .succeeded : .failed,
            didSave: didSave, checkpoints: checkpoints, errorDomain: failure?.domain,
            errorCode: failure?.code, history: nil)
        // Enqueue only after transaction queues and rollback have unwound. Never call
        // the application delegate synchronously as part of returning a transaction.
        DispatchQueue.main.async { [weak graph] in graph?.emit(.transactionDiagnostic(trace)) }
        let coordinator = self.coordinator
        DispatchQueue.global(qos: .utility).async { [weak graph] in
            let history = Self.readHistory(coordinator: coordinator, from: trace.startedAt, through: trace.finishedAt)
            let supplement = GraphTransactionTrace(diagnosticID: trace.diagnosticID, phase: .history,
                startedAt: trace.startedAt, finishedAt: trace.finishedAt, outcome: trace.outcome,
                didSave: trace.didSave, checkpoints: [], errorDomain: trace.errorDomain,
                errorCode: trace.errorCode, history: history)
            DispatchQueue.main.async { [weak graph] in graph?.emit(.transactionDiagnostic(supplement)) }
        }
    }

    /// Bounded public history read. It is never a guard and never changes the original result.
    static func readHistory(coordinator: NSPersistentStoreCoordinator?, from: Date, through: Date) -> GraphTransactionTrace.History {
        typealias History = GraphTransactionTrace.History
        func unavailable(_ error: Error?) -> History {
            let failure = error as NSError?
            return History(status: .unavailable, from: from, through: through, observedChanges: 0,
                groups: [], truncated: false, isExhaustive: false,
                errorDomain: failure?.domain, errorCode: failure?.code)
        }
        guard let coordinator, !coordinator.persistentStores.isEmpty,
              coordinator.persistentStores.allSatisfy({ $0.type == NSSQLiteStoreType }) else { return unavailable(nil) }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        return context.performAndWait {
            defer { context.reset() }
            do {
                // Use the public date-based request: timestamp predicates with NSDate
                // constants raise an Objective-C exception on macOS 14. Apply the
                // upper boundary to the returned transactions below.
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: from)
                guard let countFetch = NSPersistentHistoryChange.fetchRequest else { return unavailable(nil) }
                let countRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: from)
                countRequest.fetchRequest = countFetch
                countRequest.resultType = .count
                let countResult = try context.execute(countRequest) as? NSPersistentHistoryResult
                guard let count = countResult?.result as? NSNumber else { return unavailable(nil) }
                // Core Data does not enforce fetchLimit on these history requests on
                // the tested SDKs. Refuse large detail reads before materialization.
                // This count is conservative: it also includes newer history after
                // the outcome. Count and detail reads are not an atomic boundary.
                if count.intValue > 512 {
                    return History(status: .available, from: from, through: through,
                        observedChanges: 0, groups: [], truncated: true, isExhaustive: false,
                        errorDomain: nil, errorCode: nil)
                }
                request.resultType = .transactionsAndChanges
                guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction] else { return unavailable(nil) }
                let changes = transactions.flatMap { $0.changes ?? [] }
                struct Key: Hashable { let author: String?; let entity: String; let operation: String }
                var counts: [Key: Int] = [:]
                var clipped = changes.count > 512
                let observed = changes.prefix(512).filter {
                    guard let date = $0.transaction?.timestamp else { return false }
                    return date >= from && date <= through
                }
                for change in observed {
                    let author = change.transaction?.author
                    let entity = change.changedObjectID.entity.name ?? "unknown"
                    if (author?.count ?? 0) > 128 || entity.count > 128 { clipped = true }
                    let operation: String
                    switch change.changeType {
                    case .insert: operation = "insert"
                    case .update: operation = "update"
                    case .delete: operation = "delete"
                    @unknown default: operation = "unknown"
                    }
                    let key = Key(author: author.map { String($0.prefix(128)) },
                                  entity: String(entity.prefix(128)), operation: operation)
                    counts[key, default: 0] += 1
                }
                let keys = counts.keys.sorted {
                    if $0.author != $1.author { return ($0.author ?? "") < ($1.author ?? "") }
                    if $0.entity != $1.entity { return $0.entity < $1.entity }
                    return $0.operation < $1.operation
                }
                clipped = clipped || keys.count > 64
                let groups = keys.prefix(64).map { History.Group(author: $0.author,
                    entityName: $0.entity, operation: $0.operation, count: counts[$0]!) }
                return History(status: .available, from: from, through: through,
                    observedChanges: observed.count, groups: groups, truncated: clipped,
                    isExhaustive: false, errorDomain: nil, errorCode: nil)
            } catch { return unavailable(error) }
        }
    }
}
