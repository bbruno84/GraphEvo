import Foundation
import GraphEvoModel

package enum GraphLedgerError: Error, Equatable {
    case unavailable, readOnly, invalidData, limitExceeded, operationInProgress, staleOperation, conflict, recoveryRequired
}
package enum GraphLedgerPhase: String, Codable, Sendable {
    case running, interrupted, succeeded, failed, cancelled
    var terminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}
package struct GraphLedgerOperation: Codable, Equatable, Sendable {
    package let id: UUID
    package var origin: UUID
    package let kind: String
    package var phase: String
    package var state: GraphLedgerPhase
    package var attempts: UInt64
    package let startedAt: Date
    package var updatedAt: Date
    package var finishedAt: Date?
    package var failure: String?
    package var information: Data
}
package struct GraphLedgerEvent: Codable, Equatable, Sendable {
    package let id: UUID
    package let operationID: UUID
    package let state: GraphLedgerPhase
    package let phase: String
    package let date: Date
    package let attempts: UInt64
    package let summary: String
}
package struct GraphLedger: Codable, Equatable, Sendable {
    package let graphID: GraphID
    package var revision: UUID
    package var current: GraphLedgerOperation?
    package var previous: GraphLedgerOperation?
    package var history: [GraphLedgerEvent]
    package var information: Data

    static let maximumHistory = 32
    static let maximumPayloadBytes = 128 * 1024
    static let emptyInformation = Data("{}".utf8)
    static func empty(_ id: GraphID) -> Self {
        .init(graphID: id, revision: UUID(), current: nil, previous: nil, history: [], information: emptyInformation)
    }
    func validate() throws {
        _ = try Self.json(information)
        guard history.count <= Self.maximumHistory, Set(history.map(\.id)).count == history.count,
              previous?.state.terminal != false, current?.id != previous?.id || current == nil else { throw GraphLedgerError.invalidData }
        for operation in [current, previous].compactMap({ $0 }) {
            guard Self.text(operation.kind, maximum: 128), Self.text(operation.phase, maximum: 128),
                  operation.attempts > 0, operation.startedAt.timeIntervalSince1970.isFinite,
                  operation.updatedAt.timeIntervalSince1970.isFinite,
                  operation.state.terminal == (operation.finishedAt != nil),
                  operation.finishedAt?.timeIntervalSince1970.isFinite != false,
                  operation.failure.map({ Self.text($0, maximum: 2048) }) != false else { throw GraphLedgerError.invalidData }
            _ = try Self.json(operation.information)
        }
        for event in history {
            guard Self.text(event.phase, maximum: 128), event.attempts > 0, event.date.timeIntervalSince1970.isFinite,
                  Self.text(event.summary, maximum: 256) else { throw GraphLedgerError.invalidData }
        }
        guard try JSONEncoder().encode(self).count <= Self.maximumPayloadBytes else { throw GraphLedgerError.limitExceeded }
    }
    static func text(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum
    }
    /// The consumer owns this JSON object. Canonicalization makes key order a no-op;
    /// no application-format registry or domain decoding is involved.
    static func json(_ data: Data) throws -> Data {
        guard data.count <= 16 * 1024 else { throw GraphLedgerError.limitExceeded }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GraphLedgerError.invalidData }
        var items = 0
        func visit(_ value: Any, depth: Int) throws {
            items += 1
            guard depth <= 8, items <= 1024 else { throw GraphLedgerError.limitExceeded }
            if let fields = value as? [String: Any] {
                for (key, value) in fields {
                    guard Self.text(key, maximum: 128) else { throw GraphLedgerError.invalidData }
                    try visit(value, depth: depth + 1)
                }
            } else if let values = value as? [Any] { for value in values { try visit(value, depth: depth + 1) } }
        }
        try visit(object, depth: 0)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard canonical.count <= 16 * 1024 else { throw GraphLedgerError.limitExceeded }
        return canonical
    }
}

package enum GraphLedgerMutation: Sendable {
    case begin(kind: String, phase: String, information: Data)
    case progress(operation: UUID, phase: String)
    case retry(operation: UUID, failure: String)
    case interrupt(operation: UUID, failure: String)
    case resume(operation: UUID)
    case finish(operation: UUID, outcome: GraphLedgerPhase, summary: String)
    case information(Data)
    case operationInformation(operation: UUID, json: Data)
}
extension GraphLedger {
    func applying(_ mutation: GraphLedgerMutation, origin: UUID, date: Date) throws -> Self {
        var next = self, significant = false, summary = "Updated"
        switch mutation {
        case .information(let json): next.information = try Self.json(json)
        case .begin(let kind, let phase, let information):
            guard current?.state.terminal != false else { throw GraphLedgerError.operationInProgress }
            next.previous = current ?? previous
            next.current = .init(id: UUID(), origin: origin, kind: kind, phase: phase, state: .running, attempts: 1,
                startedAt: date, updatedAt: date, finishedAt: nil, failure: nil, information: try Self.json(information))
            significant = true; summary = "Started"
        default:
            guard var operation = current else { throw GraphLedgerError.staleOperation }
            switch mutation {
            case .progress(let id, let phase):
                guard operation.id == id, operation.state == .running else { throw GraphLedgerError.staleOperation }
                significant = operation.phase != phase; operation.phase = phase; summary = "Phase changed"
            case .retry(let id, let failure):
                guard operation.id == id, operation.state == .running else { throw GraphLedgerError.staleOperation }
                guard operation.attempts < UInt64.max else { throw GraphLedgerError.limitExceeded }
                operation.attempts += 1; operation.failure = failure
            case .interrupt(let id, let failure):
                guard operation.id == id, !operation.state.terminal else { throw GraphLedgerError.staleOperation }
                significant = operation.state != .interrupted; operation.state = .interrupted; operation.failure = failure; summary = "Interrupted"
            case .resume(let id):
                guard operation.id == id, !operation.state.terminal else { throw GraphLedgerError.staleOperation }
                guard operation.attempts < UInt64.max else { throw GraphLedgerError.limitExceeded }
                operation.state = .running; operation.origin = origin; operation.attempts += 1; operation.failure = nil; significant = true; summary = "Resumed"
            case .finish(let id, let outcome, let text):
                guard operation.id == id, !operation.state.terminal, outcome.terminal else { throw GraphLedgerError.staleOperation }
                operation.state = outcome; operation.finishedAt = date; significant = true; summary = text
            case .operationInformation(let id, let json):
                guard operation.id == id else { throw GraphLedgerError.staleOperation }
                operation.information = try Self.json(json)
            default: throw GraphLedgerError.invalidData
            }
            if operation != current { operation.updatedAt = date }
            next.current = operation
        }
        if next == self { return self }
        guard date.timeIntervalSince1970.isFinite else { throw GraphLedgerError.invalidData }
        next.revision = UUID()
        if significant, let operation = next.current {
            next.history.append(.init(id: UUID(), operationID: operation.id, state: operation.state, phase: operation.phase,
                date: date, attempts: operation.attempts, summary: summary))
            next.history = Array(next.history.suffix(Self.maximumHistory))
        }
        try next.validate(); return next
    }
}

package enum GraphLedgerSyncState: String, Codable, Sendable { case idle, pending, conflict, recoveryRequired, unavailable }
package struct GraphLedgerStatus: Equatable, Sendable {
    package let ledger: GraphLedger?
    package let remote: GraphLedger?
    package let state: GraphLedgerSyncState
    package let failure: String?
    package let confirmedRevision: UUID?
}

/// One bounded local intent per registered graph; retry attempts never append durable work.
struct GraphLedgerReplica: Codable, Equatable, Sendable {
    static let maximumBytes = 512 * 1024
    let generation: UUID
    let binding: GraphCloudBinding
    let membershipGeneration: UUID?
    var value: GraphLedger
    var serverRevision: UUID?
    var pendingBase: UUID?
    var pending = false
    var inflight: GraphLedger?
    var conflicting: GraphLedger?
    var conflict = false
    var recoveryRequired = false
    var failure: String?
    var status: GraphLedgerStatus {
        .init(ledger: value, remote: conflicting,
              state: conflict ? .conflict : recoveryRequired ? .recoveryRequired : pending ? .pending : .idle, failure: failure, confirmedRevision: serverRevision)
    }
    func validate() throws {
        guard binding.graphID == value.graphID, conflicting?.graphID == nil || conflicting?.graphID == value.graphID,
              failure?.utf8.count ?? 0 <= 2048 else { throw GraphLedgerError.invalidData }
        try value.validate(); try conflicting?.validate(); try inflight?.validate()
        guard inflight?.graphID == nil || inflight?.graphID == value.graphID else { throw GraphLedgerError.invalidData }
        guard try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw GraphLedgerError.limitExceeded }
    }
}

struct GraphLedgerSignalFeed: Sendable {
    let stream: AsyncStream<Void>
    let cancel: @Sendable () -> Void
}
