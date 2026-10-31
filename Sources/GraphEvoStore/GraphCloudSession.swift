import Foundation
import GraphEvoModel

/// Native delegates convert to detached events before calling the session.
enum GraphCloudEvent: Sendable {
    case state(Data), incoming([GraphCloudIncoming]), sent(GraphCloudSentReceipt), failure(GraphCloudError), account(String?)
}

struct GraphCloudDriver: Sendable {
    let fetch: @Sendable ([GraphCloudZone]) async throws -> Void
    let cancel: @Sendable () async throws -> Void
    let send: (@Sendable (GraphCloudOutgoingBatch) async throws -> Void)?
    init(fetch: @escaping @Sendable ([GraphCloudZone]) async throws -> Void,
         cancel: @escaping @Sendable () async throws -> Void,
         send: (@Sendable (GraphCloudOutgoingBatch) async throws -> Void)? = nil) {
        self.fetch = fetch; self.cancel = cancel; self.send = send
    }
}

struct GraphCloudAdapter: Sendable {
    let account: @Sendable (String) async throws -> String
    let make: @Sendable (GraphCloudConfiguration, GraphCloudScope, Data?, @escaping @Sendable (GraphCloudEvent) async -> Void) throws -> GraphCloudDriver
}

struct GraphCloudQuarantine: Error {
    let session: GraphCloudSession
    let failure: any Error
}

/// One session owns at most one engine per scope, independently of individual graph leases.
actor GraphCloudSession {
    let configuration: GraphCloudConfiguration
    private let owner: UUID
    private let adapter: GraphCloudAdapter
    private let disk: GraphCloudDisk
    private let url: URL
    private var directoryLease: GraphCloudDirectoryLease?
    private var document: GraphCloudDocument
    private var drivers: [GraphCloudScope: GraphCloudDriver] = [:]
    private var failure: GraphCloudError?
    private var stopping: Task<Void, any Error>?
    private var cancellation: Task<Void, any Error>?
    private var stopped = false
    private var activeFetches = Set<GraphCloudScope>()
    private var fetches = 0
    private var outbound: [GraphCloudScope: GraphCloudOutgoingBatch] = [:]
    private var drains: [CheckedContinuation<Void, Never>] = []

    private init(configuration: GraphCloudConfiguration, owner: UUID, adapter: GraphCloudAdapter,
                 disk: GraphCloudDisk, lease: GraphCloudDirectoryLease, document: GraphCloudDocument) {
        self.configuration = configuration; self.owner = owner; self.adapter = adapter; self.disk = disk
        self.url = configuration.directory.appendingPathComponent("session.json")
        self.directoryLease = lease; self.document = document
    }

    static func open(_ config: GraphCloudConfiguration, adapter: GraphCloudAdapter, disk: GraphCloudDisk = .live) async throws -> GraphCloudSession {
        guard !config.containerIdentifier.isEmpty, config.directory.isFileURL,
              config.maximumEvents > 0, config.maximumBytes > 0 else { throw GraphCloudError.invalidConfiguration }
        let owner = UUID()
        try await GraphCloudOwnership.shared.acquire(config.containerIdentifier, owner: owner)
        do {
            let account = try await adapter.account(config.containerIdentifier)
            guard !account.isEmpty else { throw GraphCloudError.accountUnavailable }
            let lease = try GraphCloudDirectoryLease(directory: config.directory)
            let url = config.directory.appendingPathComponent("session.json")
            let doc: GraphCloudDocument
            if let data = try disk.read(url) {
                guard data.count <= config.maximumBytes else { throw GraphCloudError.inboxLimit }
                do { doc = try JSONDecoder().decode(GraphCloudDocument.self, from: data) }
                catch { throw GraphCloudError.invalidState }
                guard doc.format == 3, doc.container == config.containerIdentifier, doc.environment == config.environment,
                      doc.account == account else { throw GraphCloudError.invalidState }
                guard doc.states.keys.allSatisfy({ GraphCloudScope(rawValue: $0) != nil }),
                      doc.eventCount <= config.maximumEvents, doc.inbox.allSatisfy({ $0.change.valid }),
                      Set(doc.inbox.map(\.id)).count == doc.inbox.count,
                      Set(doc.bindings.map(\.zone)).count == doc.bindings.count,
                      Set(doc.bindings.map(\.graphID)).count == doc.bindings.count,
                      doc.bindings.allSatisfy({ !$0.zone.name.isEmpty && !$0.zone.owner.isEmpty }) else { throw GraphCloudError.invalidState }
                guard Set(doc.sent.map(\.id)).count == doc.sent.count else { throw GraphCloudError.invalidState }
                for receipt in doc.sent {
                    guard doc.bindings.contains(where: { $0.graphID == receipt.graphID && $0.zone == receipt.zone }) else { throw GraphCloudError.invalidState }
                    for record in receipt.saved { try GraphCloudRecordCodec.validate(record) }
                    for failure in receipt.failures { try Self.validateFailure(failure, zone: receipt.zone) }
                }
                for entry in doc.inbox { try GraphCloudRecordCodec.validate(entry.change) }
            } else {
                doc = GraphCloudDocument(container: config.containerIdentifier, environment: config.environment, account: account)
                let bytes = try JSONEncoder().encode(doc)
                guard bytes.count <= config.maximumBytes else { throw GraphCloudError.inboxLimit }
                try disk.write(url, bytes)
            }
            let session = GraphCloudSession(configuration: config, owner: owner, adapter: adapter, disk: disk, lease: lease, document: doc)
            // Restoring shared state also restores shared engine ownership, even before a graph reopens.
            do { try await session.start(restoringShared: doc.states[GraphCloudScope.shared.rawValue] != nil || doc.bindings.contains { $0.zone.scope == .shared }) }
            catch {
                let original = error
                do { try await session.stop() }
                catch { throw GraphCloudQuarantine(session: session, failure: error) }
                throw original
            }
            return session
        } catch {
            if !(error is GraphCloudQuarantine) { await GraphCloudOwnership.shared.release(config.containerIdentifier, owner: owner) }
            throw error
        }
    }

    private func start(restoringShared: Bool) throws {
        try enable(.private)
        if restoringShared { try enable(.shared) }
    }

    private func enable(_ scope: GraphCloudScope) throws {
        guard drivers[scope] == nil else { return }
        // A weak delegate closure prevents an engine/session retain cycle.
        drivers[scope] = try adapter.make(configuration, scope, document.states[scope.rawValue]) { [weak self] event in
            await self?.receive(event, scope: scope)
        }
    }

    private func check() throws {
        if let failure { throw failure }
        guard !stopped else { throw GraphCloudError.stopped }
        guard stopping == nil else { throw GraphCloudError.stopping }
    }

    private static func validateFailure(_ failure: GraphCloudRecordFailure, zone: GraphCloudZone) throws {
        if let record = failure.serverRecord {
            guard failure.code == 14, record.kind == .recordChanged, record.zone == zone,
                  record.recordName == failure.recordName else { throw GraphCloudError.invalidState }
            try GraphCloudRecordCodec.validate(record)
        }
    }

    private func publish(_ candidate: GraphCloudDocument) throws {
        guard candidate.eventCount <= configuration.maximumEvents else { throw GraphCloudError.inboxLimit }
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= configuration.maximumBytes else { throw GraphCloudError.inboxLimit }
        do { try disk.write(url, data) } catch { throw GraphCloudError.persistence }
        document = candidate
    }

    func bind(_ binding: GraphCloudBinding) throws {
        try check()
        guard !binding.zone.owner.isEmpty, !binding.zone.name.isEmpty else { throw GraphCloudError.invalidConfiguration }
        if document.bindings.contains(binding) { return }
        guard !document.bindings.contains(where: { $0.zone == binding.zone || $0.graphID == binding.graphID }) else {
            throw GraphCloudError.ownershipConflict
        }
        var next = document; next.bindings.append(binding)
        do {
            try publish(next)
            try enable(binding.zone.scope)
        } catch { block(error as? GraphCloudError ?? .persistence); throw error }
    }

    func receive(_ event: GraphCloudEvent, scope: GraphCloudScope) {
        guard failure == nil, !stopped else { return }
        // During cancellation, admitted fetch callbacks must still be persisted.
        do {
            switch event {
            case .state(let state):
                var next = document; next.states[scope.rawValue] = state; try publish(next)
            case .incoming(let changes):
                guard changes.allSatisfy({ $0.valid && $0.zone.scope == scope }) else { throw GraphCloudError.invalidState }
                for change in changes { try GraphCloudRecordCodec.validate(change) }
                guard changes.count <= configuration.maximumEvents - document.eventCount else { throw GraphCloudError.inboxLimit }
                var next = document
                next.inbox += changes.map { GraphCloudInboxEntry(id: UUID(), change: $0) }
                if !changes.isEmpty { try publish(next) }
            case .sent(let receipt):
                guard let batch = outbound[scope], receipt.batchID == batch.id, receipt.graphID == batch.graphID,
                      receipt.zone == batch.zone, receipt.zone.scope == scope else { throw GraphCloudError.invalidState }
                let items = Dictionary(uniqueKeysWithValues: batch.items.map { ($0.recordName, $0.change.operation) })
                let names = receipt.saved.compactMap(\.recordName) + receipt.deletedNames + receipt.failures.map(\.recordName)
                if names.isEmpty { return }
                guard Set(names).count == names.count,
                      receipt.saved.allSatisfy({ $0.kind == .recordChanged && $0.zone == batch.zone && $0.recordName.flatMap { items[$0] } == .save }),
                      receipt.deletedNames.allSatisfy({ items[$0] == .delete }),
                      receipt.failures.allSatisfy({ items[$0.recordName] != nil }) else { throw GraphCloudError.invalidState }
                for record in receipt.saved { try GraphCloudRecordCodec.validate(record) }
                for failure in receipt.failures { try Self.validateFailure(failure, zone: receipt.zone) }
                var next = document; next.sent.append(receipt); try publish(next)
            case .failure(let error): throw error
            case .account(let account):
                guard account == document.account else { throw GraphCloudError.accountChanged }
            }
        } catch { block(error as? GraphCloudError ?? .persistence) }
    }

    private static func cancelAll(_ drivers: [GraphCloudDriver]) async throws {
        var failure: (any Error)?
        for driver in drivers {
            do { try await driver.cancel() }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    private func block(_ error: GraphCloudError) {
        guard failure == nil else { return }
        failure = error
        let values = Array(drivers.values)
        // Never await cancellation from the serial native delegate callback.
        cancellation = Task { try await Self.cancelAll(values) }
    }

    func routes(in scope: GraphCloudScope) throws -> [GraphCloudBinding] {
        try check()
        return document.bindings.filter { $0.zone.scope == scope }
    }

    func fetch(_ scope: GraphCloudScope, zones selected: Set<GraphCloudZone>? = nil) async throws {
        try check()
        guard let driver = drivers[scope] else { throw GraphCloudError.invalidConfiguration }
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        fetches += 1
        defer {
            activeFetches.remove(scope)
            fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        let zones = document.bindings.filter { $0.zone.scope == scope }.map(\.zone)
        if let selected { guard selected.isSubset(of: Set(zones)) else { throw GraphCloudError.invalidConfiguration } }
        try await driver.fetch(zones.filter { selected?.contains($0) ?? true })
        if let failure { throw failure }
    }

    func identity() throws -> GraphCloudSessionIdentity {
        try check()
        return GraphCloudSessionIdentity(container: document.container, environment: document.environment, account: document.account)
    }
    func send(_ batch: GraphCloudOutgoingBatch) async throws {
        try check()
        let scope = batch.zone.scope
        guard let send = drivers[scope]?.send else { throw GraphCloudError.transportUnavailable }
        guard document.bindings.contains(where: { $0.zone == batch.zone && $0.graphID == batch.graphID }) else { throw GraphCloudError.invalidState }
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        fetches += 1; outbound[scope] = batch
        defer {
            outbound.removeValue(forKey: scope); activeFetches.remove(scope); fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        try await send(batch)
        if let failure { throw failure }
    }
    func sentReceipts(for graph: GraphID) throws -> [GraphCloudSentReceipt] {
        try check(); return document.sent.filter { $0.graphID == graph }
    }
    func incoming(for zone: GraphCloudZone, limit: Int) throws -> [GraphCloudInboxEntry] {
        try check()
        guard limit > 0 else { throw GraphCloudError.invalidConfiguration }
        let deletion = document.inbox.filter { $0.change.zone == zone && $0.change.kind == .zoneDeleted }
        if !deletion.isEmpty { return Array(deletion.prefix(limit)) }
        return Array(document.inbox.lazy.filter { $0.change.zone == zone }.prefix(limit))
    }
    func retainedReceiptIDs(for graph: GraphID) throws -> Set<UUID> {
        try check()
        let zones = Set(document.bindings.filter { $0.graphID == graph }.map(\.zone))
        return Set(document.inbox.filter { zones.contains($0.change.zone) }.map(\.id))
            .union(document.sent.filter { $0.graphID == graph }.map(\.id))
    }
    func consume(_ ids: Set<UUID>) throws {
        try check()
        var next = document
        next.inbox.removeAll { ids.contains($0.id) }; next.sent.removeAll { ids.contains($0.id) }
        do { try publish(next) } catch { block(error as? GraphCloudError ?? .persistence); throw error }
    }
    func route(for graph: GraphID) throws -> GraphCloudBinding {
        try check()
        guard let route = document.bindings.first(where: { $0.graphID == graph }) else { throw GraphCloudError.invalidConfiguration }
        return route
    }

    func startStatus() throws -> GraphCloudStatus { try check(); return status() }

    func status() -> GraphCloudStatus {
        GraphCloudStatus(scopes: Set(drivers.keys), inboxCount: document.inbox.count, failure: failure, stopped: stopped, outgoingReceiptCount: document.sent.count)
    }
    func inbox(limit: Int) throws -> [GraphCloudInboxEntry] {
        guard limit > 0 else { throw GraphCloudError.invalidConfiguration }
        return Array(document.inbox.prefix(limit))
    }
    func binding(for zone: GraphCloudZone) -> GraphCloudBinding? { document.bindings.first { $0.zone == zone } }

    func stop() async throws {
        if let stopping { return try await stopping.value }
        if stopped { return }
        let values = Array(drivers.values), cancellation = cancellation
        let job = Task {
            if let cancellation { try await cancellation.value }
            else { try await Self.cancelAll(values) }
            await self.finishStop()
        }
        stopping = job
        try await job.value
    }

    private func finishStop() async {
        if fetches > 0 { await withCheckedContinuation { drains.append($0) } }
        stopped = true
        drivers.removeAll(); directoryLease = nil
        await GraphCloudOwnership.shared.release(configuration.containerIdentifier, owner: owner)
    }
}
