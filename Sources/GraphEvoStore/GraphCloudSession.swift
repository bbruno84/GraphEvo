import Foundation
import GraphEvoModel

/// Native delegates convert to detached events before calling the session.
enum GraphCloudEvent: Sendable {
    case state(Data), incoming([GraphCloudIncoming]), failure(GraphCloudError), account(String?)
}

struct GraphCloudDriver: Sendable {
    let fetch: @Sendable ([GraphCloudZone]) async throws -> Void
    let cancel: @Sendable () async throws -> Void
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
                guard doc.format == 1, doc.container == config.containerIdentifier, doc.environment == config.environment,
                      doc.account == account else { throw GraphCloudError.invalidState }
                guard doc.states.keys.allSatisfy({ GraphCloudScope(rawValue: $0) != nil }),
                      doc.inbox.count <= config.maximumEvents, doc.inbox.allSatisfy({ $0.change.valid }),
                      Set(doc.inbox.map(\.id)).count == doc.inbox.count,
                      Set(doc.bindings.map(\.zone)).count == doc.bindings.count,
                      Set(doc.bindings.map(\.graphID)).count == doc.bindings.count,
                      Set(doc.bindings.map(\.storeURL)).count == doc.bindings.count,
                      doc.bindings.allSatisfy({ $0.storeURL.isFileURL && !$0.zone.name.isEmpty && !$0.zone.owner.isEmpty }) else { throw GraphCloudError.invalidState }
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

    private func publish(_ candidate: GraphCloudDocument) throws {
        guard candidate.inbox.count <= configuration.maximumEvents else { throw GraphCloudError.inboxLimit }
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= configuration.maximumBytes else { throw GraphCloudError.inboxLimit }
        do { try disk.write(url, data) } catch { throw GraphCloudError.persistence }
        document = candidate
    }

    func bind(_ binding: GraphCloudBinding) throws {
        try check()
        guard binding.storeURL.isFileURL, !binding.zone.owner.isEmpty, !binding.zone.name.isEmpty else { throw GraphCloudError.invalidConfiguration }
        if document.bindings.contains(binding) { return }
        guard !document.bindings.contains(where: { $0.zone == binding.zone || $0.graphID == binding.graphID || $0.storeURL == binding.storeURL }) else {
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
                guard changes.count <= configuration.maximumEvents - document.inbox.count else { throw GraphCloudError.inboxLimit }
                var next = document
                next.inbox += changes.map { GraphCloudInboxEntry(id: UUID(), change: $0) }
                if !changes.isEmpty { try publish(next) }
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

    func fetch(_ scope: GraphCloudScope) async throws {
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
        try await driver.fetch(zones)
        if let failure { throw failure }
    }

    func startStatus() throws -> GraphCloudStatus { try check(); return status() }

    func status() -> GraphCloudStatus {
        GraphCloudStatus(scopes: Set(drivers.keys), inboxCount: document.inbox.count, failure: failure, stopped: stopped)
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
