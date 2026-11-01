import Foundation
import GraphEvoModel

/// Native delegates convert to detached events before calling the session.
enum GraphCloudEvent: Sendable {
    case retryAdvice(TimeInterval)
    case state(Data), incoming([GraphCloudIncoming]), sent(GraphCloudSentReceipt), failure(GraphCloudError), account(String?)
}

struct GraphCloudDriver: Sendable {
    let fetch: @Sendable ([GraphCloudZone]) async throws -> Void
    let cancel: @Sendable () async throws -> Void
    let forget: (@Sendable (GraphCloudZone) async throws -> Void)?
    let send: (@Sendable (GraphCloudOutgoingBatch) async throws -> Void)?
    init(fetch: @escaping @Sendable ([GraphCloudZone]) async throws -> Void,
         cancel: @escaping @Sendable () async throws -> Void,
         send: (@Sendable (GraphCloudOutgoingBatch) async throws -> Void)? = nil,
         forget: (@Sendable (GraphCloudZone) async throws -> Void)? = nil) {
        self.fetch = fetch; self.cancel = cancel; self.send = send; self.forget = forget
    }
}

/// Captured while the scope is still owned, including failure advice. Never persisted.
struct GraphCloudSendOutcome: Sendable {
    let transportError: (any Error)?
    let retryAfter: TimeInterval?
}

struct GraphCloudAdapter: Sendable {
    var sharing: GraphCloudSharingService? = nil
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
    private var sharingObservers: [GraphID: [UUID: AsyncStream<GraphCloudSharingStatus>.Continuation]] = [:]
    private var driverGenerations: [GraphCloudScope: UUID] = [:]
    private var drivers: [GraphCloudScope: GraphCloudDriver] = [:]
    private var failure: GraphCloudError?
    private var stopping: Task<Void, any Error>?
    private var cancellation: Task<Void, any Error>?
    private var stopped = false
    private var retryAdvice: [GraphCloudScope: TimeInterval] = [:]
    private var activeFetches = Set<GraphCloudScope>()
    private var shareCreation: UUID?
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
                guard doc.format == 5, doc.container == config.containerIdentifier, doc.environment == config.environment,
                      doc.account == account else { throw GraphCloudError.invalidState }
                guard doc.states.keys.allSatisfy({ GraphCloudScope(rawValue: $0) != nil }),
                      doc.eventCount <= config.maximumEvents, doc.inbox.allSatisfy({ $0.change.valid }),
                      Set(doc.inbox.map(\.id)).count == doc.inbox.count,
                      Set(doc.bindings.map(\.zone)).count == doc.bindings.count,
                      Set(doc.bindings.map(\.graphID)).count == doc.bindings.count,
                      doc.bindings.allSatisfy({ !$0.zone.name.isEmpty && !$0.zone.owner.isEmpty }),
                      Set(doc.shareAttempts).count == doc.shareAttempts.count,
                      doc.shareAttempts.allSatisfy({ zone in zone.scope == .private && doc.bindings.contains { $0.zone == zone } }) else { throw GraphCloudError.invalidState }
                guard Set(doc.memberships.map { $0.binding.graphID }).count == doc.memberships.count,
                      Set(doc.memberships.map(\.generation)).count == doc.memberships.count,
                      doc.memberships.allSatisfy({ $0.identity == GraphCloudSessionIdentity(container: doc.container, environment: doc.environment, account: doc.account)
                        && !$0.binding.zone.owner.isEmpty && !$0.binding.zone.name.isEmpty
                        && (($0.role == .owner) == ($0.binding.zone.scope == .private))
                        && ($0.role == .owner || $0.storeID?.isEmpty == false)
                        && ($0.phase != .removed || !doc.bindings.contains($0.binding))
                      }) else { throw GraphCloudError.invalidState }
                guard Set(doc.sent.map(\.id)).count == doc.sent.count else { throw GraphCloudError.invalidState }
                for receipt in doc.sent {
                    guard doc.bindings.contains(where: { $0.graphID == receipt.graphID && $0.zone == receipt.zone }) else { throw GraphCloudError.invalidState }
                    for record in receipt.saved { try GraphCloudRecordCodec.validate(record) }
                    for failure in receipt.failures { try Self.validateFailure(failure, zone: receipt.zone) }
                }
                for entry in doc.inbox {
                    if let member = doc.memberships.first(where: { $0.role == .participant && $0.binding.zone == entry.change.zone }) {
                        guard entry.membershipGeneration == member.generation else { throw GraphCloudError.invalidState }
                    }
                    try GraphCloudRecordCodec.validate(entry.change)
                }
                for receipt in doc.sent {
                    if let member = doc.memberships.first(where: { $0.role == .participant && $0.binding.graphID == receipt.graphID }) {
                        guard receipt.membershipGeneration == member.generation else { throw GraphCloudError.invalidState }
                    }
                }
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
        let generation = UUID(); driverGenerations[scope] = generation
        drivers[scope] = try adapter.make(configuration, scope, document.states[scope.rawValue]) { [weak self] event in
            await self?.receive(event, scope: scope, driverGeneration: generation)
        }
    }

    private func check(control: Bool = false) throws {
        if let failure, !(control && failure == .inboxLimit) { throw failure }
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

    private func publish(_ candidate: GraphCloudDocument, reservingControl: Bool = false) throws {
        guard candidate.eventCount <= configuration.maximumEvents else { throw GraphCloudError.inboxLimit }
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= configuration.maximumBytes else { throw GraphCloudError.inboxLimit }
        if reservingControl {
            // Keep bounded space for removal intent, diagnostics and offline leave commands.
            let participants = candidate.memberships.filter { $0.role == .participant && $0.phase != .removed }.count
            let headroom = participants.multipliedReportingOverflow(by: 1024)
            guard !headroom.overflow, headroom.partialValue <= configuration.maximumBytes - data.count else { throw GraphCloudError.inboxLimit }
        }
        do { try disk.write(url, data) } catch { throw GraphCloudError.persistence }
        document = candidate
        for member in candidate.memberships {
            for observer in sharingObservers[member.binding.graphID]?.values ?? [:].values { observer.yield(member.status) }
        }
    }

    func bind(_ binding: GraphCloudBinding) throws {
        try check()
        guard !binding.zone.owner.isEmpty, !binding.zone.name.isEmpty else { throw GraphCloudError.invalidConfiguration }
        if document.memberships.contains(where: { $0.binding.graphID == binding.graphID && $0.terminal }) { throw GraphCloudError.zoneUnavailable }
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

    func receive(_ event: GraphCloudEvent, scope: GraphCloudScope, driverGeneration: UUID? = nil) {
        if let driverGeneration, driverGenerations[scope] != driverGeneration { return }
        guard !stopped else { return }
        if failure != nil {
            guard failure == .inboxLimit else { return }
            // Saturated application transport must not hide a later account/session failure.
            switch event { case .account, .failure: break; default: return }
        }
        // During cancellation, admitted fetch callbacks must still be persisted.
        do {
            switch event {
            case .retryAdvice(let seconds):
                if seconds.isFinite && seconds >= 0 { retryAdvice[scope] = max(retryAdvice[scope] ?? 0, seconds) }
            case .state(let state):
                var next = document; next.states[scope.rawValue] = state; try publish(next, reservingControl: true)
            case .incoming(let incoming):
                let removed = Set(document.memberships.filter { $0.role == .participant && $0.terminal }.map { $0.binding.zone })
                let changes = incoming.filter { !removed.contains($0.zone) }
                guard changes.allSatisfy({ $0.valid && $0.zone.scope == scope }) else { throw GraphCloudError.invalidState }
                for change in changes { try GraphCloudRecordCodec.validate(change) }
                guard changes.count <= configuration.maximumEvents - document.eventCount else { throw GraphCloudError.inboxLimit }
                var next = document
                next.inbox += changes.compactMap { change in
                    let member = next.memberships.first { $0.binding.zone == change.zone && $0.role == .participant }
                    return GraphCloudInboxEntry(id: UUID(), change: change, membershipGeneration: member?.generation)
                }
                if !changes.isEmpty { try publish(next, reservingControl: true) }
            case .sent(var receipt):
                guard let batch = outbound[scope], receipt.batchID == batch.id, receipt.graphID == batch.graphID,
                      receipt.zone == batch.zone, receipt.zone.scope == scope else { throw GraphCloudError.invalidState }
                let member = document.memberships.first { $0.binding.graphID == receipt.graphID && $0.role == .participant }
                if member?.terminal == true { return }
                let items = Dictionary(uniqueKeysWithValues: batch.items.map { ($0.recordName, $0.change.operation) })
                let names = receipt.saved.compactMap(\.recordName) + receipt.deletedNames + receipt.failures.map(\.recordName)
                if names.isEmpty { return }
                guard Set(names).count == names.count,
                      receipt.saved.allSatisfy({ $0.kind == .recordChanged && $0.zone == batch.zone && $0.recordName.flatMap { items[$0] } == .save }),
                      receipt.deletedNames.allSatisfy({ items[$0] == .delete }),
                      receipt.failures.allSatisfy({ items[$0.recordName] != nil }) else { throw GraphCloudError.invalidState }
                for record in receipt.saved { try GraphCloudRecordCodec.validate(record) }
                for failure in receipt.failures { try Self.validateFailure(failure, zone: receipt.zone) }
                if let member {
                    receipt.membershipGeneration = member.generation
                }
                var next = document; next.sent.append(receipt); try publish(next, reservingControl: true)
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
        guard failure == nil || (failure == .inboxLimit && error != .inboxLimit) else { return }
        failure = error
        let values = Array(drivers.values)
        // Never await cancellation from the serial native delegate callback.
        if cancellation == nil { cancellation = Task { try await Self.cancelAll(values) } }
    }

    func routes(in scope: GraphCloudScope) throws -> [GraphCloudBinding] {
        try check()
        return document.bindings.filter { $0.zone.scope == scope }
    }

    func fetch(_ scope: GraphCloudScope, zones selected: Set<GraphCloudZone>? = nil) async throws {
        try check()
        guard let driver = drivers[scope] else { throw GraphCloudError.invalidConfiguration }
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        retryAdvice[scope] = nil
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

    /// Control operations share the engine scope gate and participate in session stop draining.
    private func control<Value: Sendable>(_ scope: GraphCloudScope, allowingDataLimit: Bool = false,
        body: @Sendable (GraphCloudSharingService, String) async throws -> Value) async throws -> Value {
        try check(control: allowingDataLimit)
        guard let sharing = adapter.sharing else { throw GraphCloudSharingError.unavailable }
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        fetches += 1
        defer {
            activeFetches.remove(scope); fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        let result = try await body(sharing, document.account)
        if let failure, !(allowingDataLimit && failure == .inboxLimit) { throw failure }
        return result
    }

    func invite(_ binding: GraphCloudBinding, recipient: String, permission: GraphCloudSharePermission) async throws -> GraphCloudInvitation {
        try check()
        guard document.bindings.contains(binding), binding.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
        guard !recipient.isEmpty, recipient != document.account else { throw GraphCloudSharingError.invalidParticipant }
        guard adapter.sharing != nil else { throw GraphCloudSharingError.unavailable }
        guard !activeFetches.contains(.private) else { throw GraphCloudError.busy }
        let mayCreate = !document.shareAttempts.contains(binding.zone)
        let operation = UUID()
        shareCreation = operation
        defer { if shareCreation == operation { shareCreation = nil } }
        let config = configuration
        return try await control(.private) { service, account in
            try await service.invite(config, binding, account, recipient, permission, mayCreate) { [weak self] in
                guard let self else { throw GraphCloudError.stopped }
                try await self.recordShareCreation(binding, operation: operation)
            }
        }
    }

    private func recordShareCreation(_ binding: GraphCloudBinding, operation: UUID) throws {
        try check()
        guard shareCreation == operation, activeFetches.contains(.private),
              document.bindings.contains(binding) else { throw GraphCloudError.invalidState }
        guard !document.shareAttempts.contains(binding.zone) else { throw GraphCloudSharingError.metadataPending }
        var next = document; next.shareAttempts.append(binding.zone)
        try publish(next)
    }

    func accept(_ invitation: GraphCloudInvitation) async throws -> GraphCloudParticipantAccess {
        try invitation.validate()
        guard invitation.container == configuration.containerIdentifier, invitation.environment == configuration.environment,
              invitation.recipient == document.account else { throw GraphCloudSharingError.invalidInvitation }
        let binding = GraphCloudBinding(zone: invitation.zone, graphID: invitation.graphID)
        guard !document.bindings.contains(where: { ($0.graphID == binding.graphID || $0.zone == binding.zone) && $0 != binding }) else { throw GraphCloudError.ownershipConflict }
        let config = configuration
        let permission = try await control(.shared) { service, account in try await service.accept(config, invitation, account) }
        try bind(binding)
        var member = document.memberships.first { $0.binding.graphID == invitation.graphID }
        if var value = member { value.permission = permission; try updateMembership(value); member = value }
        return GraphCloudParticipantAccess(binding: binding, account: document.account, permission: permission, accepted: true,
            identity: try identity(), generation: member?.generation)
    }

    func identity(control: Bool = false) throws -> GraphCloudSessionIdentity {
        try check(control: control)
        return GraphCloudSessionIdentity(container: document.container, environment: document.environment, account: document.account)
    }
    func send(_ batch: GraphCloudOutgoingBatch) async throws {
        let result = try await sendWithAdvice(batch)
        if let error = result.transportError { throw error }
    }

    func sendWithAdvice(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSendOutcome {
        try check()
        let scope = batch.zone.scope
        guard let send = drivers[scope]?.send else { throw GraphCloudError.transportUnavailable }
        guard document.bindings.contains(where: { $0.zone == batch.zone && $0.graphID == batch.graphID }) else { throw GraphCloudError.invalidState }
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        retryAdvice[scope] = nil
        fetches += 1; outbound[scope] = batch
        defer {
            outbound.removeValue(forKey: scope); activeFetches.remove(scope); fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        do {
            try await send(batch)
            if let failure { throw failure }
            return GraphCloudSendOutcome(transportError: nil, retryAfter: retryAdvice[scope])
        } catch {
            return GraphCloudSendOutcome(transportError: error, retryAfter: retryAdvice[scope])
        }
    }
    func sentReceipts(for graph: GraphID) throws -> [GraphCloudSentReceipt] {
        try check(); return document.sent.filter { $0.graphID == graph }
    }
    func incoming(for zone: GraphCloudZone, limit: Int) throws -> [GraphCloudInboxEntry] {
        try check()
        guard limit > 0 else { throw GraphCloudError.invalidConfiguration }
        let deletion = document.inbox.filter { $0.change.zone == zone && $0.change.kind == .zoneDeleted }
        if !deletion.isEmpty { return Array(deletion.prefix(limit)) }
        // Access controls must not be hidden by a bounded, potentially undecodable application prefix.
        let controls = document.inbox.filter { $0.change.zone == zone && GraphCloudShareControl.isControl($0.change) }
        let selected = Array(controls.prefix(limit))
        let application = document.inbox.lazy.filter { $0.change.zone == zone && !GraphCloudShareControl.isControl($0.change) }
        return selected + application.prefix(limit - selected.count)
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
        drivers.removeAll(); driverGenerations.removeAll(); directoryLease = nil
        for values in sharingObservers.values { for value in values.values { value.finish() } }; sharingObservers.removeAll()
        await GraphCloudOwnership.shared.release(configuration.containerIdentifier, owner: owner)
    }
}

extension GraphCloudSession {
    private func acceptsDriver(_ scope: GraphCloudScope, generation: UUID) -> Bool { driverGenerations[scope] == generation }

    private func verifySharingAccount(_ expected: String) async throws {
        let actual = try await adapter.account(configuration.containerIdentifier)
        guard actual == expected else { block(.accountChanged); throw GraphCloudError.accountChanged }
        try check(control: true)
    }
    func memberships() throws -> [GraphCloudMembership] { try check(control: true); return document.memberships }
    func membership(_ id: GraphID) throws -> GraphCloudMembership? { try check(control: true); return document.memberships.first { $0.binding.graphID == id } }
    func updateMembership(_ value: GraphCloudMembership) throws {
        try check(control: true)
        if let prior = document.memberships.first(where: { $0.binding.graphID == value.binding.graphID }) {
            guard prior.generation == value.generation, prior.binding == value.binding else { throw GraphCloudError.invalidState }
        }
        var next = document; next.memberships.removeAll { $0.binding.graphID == value.binding.graphID }; next.memberships.append(value)
        try publish(next)
    }
    func beginMembership(_ binding: GraphCloudBinding, storeID: String, shareIdentity: String) async throws -> GraphCloudMembership {
        try check()
        if let existing = try membership(binding.graphID) {
            guard existing.binding == binding else { throw GraphCloudError.ownershipConflict }
            if existing.phase != .removed {
                guard !existing.terminal, existing.storeID == storeID else { throw GraphCloudError.zoneUnavailable }
                return existing
            }
            guard existing.pending == nil, existing.storeID != storeID else { throw GraphCloudError.busy }
            try await resetSharedDriver()
        }
        let member = GraphCloudMembership(binding: binding, identity: try identity(), generation: UUID(), role: .participant,
            phase: .joining, permission: nil, storeID: storeID, shareIdentity: shareIdentity)
        var next = document; next.memberships.removeAll { $0.binding.graphID == binding.graphID }; next.memberships.append(member)
        next.inbox.removeAll { $0.change.zone == binding.zone }
        next.sent.removeAll { $0.graphID == binding.graphID }
        try publish(next); return member
    }
    func inspectSharing(_ binding: GraphCloudBinding) async throws -> GraphCloudShareSnapshot? {
        let config = configuration
        return try await control(binding.zone.scope, allowingDataLimit: true) { service, account in
            guard let inspect = service.operations?.inspect else { throw GraphCloudSharingError.unavailable }
            try await self.verifySharingAccount(account)
            return try await inspect(config, binding, account)
        }
    }
    func supportsSharingOperations() -> Bool { adapter.sharing?.operations != nil }

    func backupSnapshot(for id: GraphID) throws -> Data? {
        let binding = document.bindings.first { $0.graphID == id }
        let membership = document.memberships.first { $0.binding.graphID == id }
        guard let zone = binding?.zone ?? membership?.binding.zone else { return nil }
        try check(control: true)
        let value = GraphCloudBackupSnapshot(format: 1, capturedAt: Date(), identity: try identity(control: true), binding: binding,
            membership: membership, inbox: document.inbox.filter { $0.change.zone == zone }, receipts: document.sent.filter { $0.graphID == id })
        return try JSONEncoder().encode(value)
    }

    func executeSharing(_ member: GraphCloudMembership) async throws {
        guard let intent = member.pending else { return }
        let config = configuration
        try await control(member.binding.zone.scope, allowingDataLimit: true) { service, account in
            guard let execute = service.operations?.execute else { throw GraphCloudSharingError.unavailable }
            try await self.verifySharingAccount(account)
            try await execute(config, member.binding, account, intent)
        }
        guard var current = try membership(member.binding.graphID), current.generation == member.generation, current.pending?.id == intent.id else { throw GraphCloudError.invalidState }
        current.pending = nil; current.failure = nil
        if intent.command == .stop {
            current.shareIdentity = nil
            var next = document; next.shareAttempts.removeAll { $0 == member.binding.zone }
            next.memberships.removeAll { $0.binding.graphID == member.binding.graphID }; next.memberships.append(current)
            try publish(next)
        } else { try updateMembership(current) }
    }
    func completePurge(_ id: GraphID, generation: UUID) async throws {
        guard var member = try membership(id), member.generation == generation, member.role == .participant, member.terminal else { throw GraphCloudError.invalidState }
        if let forget = drivers[member.binding.zone.scope]?.forget {
            let zone = member.binding.zone
            try await control(zone.scope, allowingDataLimit: true) { _, _ in try await forget(zone) }
        }
        member.phase = .removed; member.permission = nil; member.failure = nil
        var next = document
        next.inbox.removeAll { $0.change.zone == member.binding.zone }
        next.sent.removeAll { $0.graphID == id }
        next.bindings.removeAll { $0.graphID == id }
        next.memberships.removeAll { $0.binding.graphID == id }; next.memberships.append(member)
        try publish(next)
    }
    func observeSharing(_ id: GraphID) throws -> AsyncStream<GraphCloudSharingStatus> {
        guard let value = try membership(id) else { throw GraphStoreError.missingGraph }
        let token = UUID(), pair = AsyncStream<GraphCloudSharingStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sharingObservers[id, default: [:]][token] = pair.continuation
        pair.continuation.yield(value.status)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSharingObserver(id, token: token) } }
        return pair.stream
    }
    private func removeSharingObserver(_ id: GraphID, token: UUID) { sharingObservers[id]?.removeValue(forKey: token) }

    /// Never edit opaque Apple tokens. Drain/cancel one scope before replacing its sole driver.
    private func resetSharedDriver() async throws {
        try check()
        guard activeFetches.insert(.shared).inserted else { throw GraphCloudError.busy }
        fetches += 1
        defer {
            activeFetches.remove(.shared); fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        try await drivers[.shared]?.cancel()
        try check()
        driverGenerations.removeValue(forKey: .shared); drivers.removeValue(forKey: .shared)
        var next = document; next.states.removeValue(forKey: GraphCloudScope.shared.rawValue)
        try publish(next)
        try enable(.shared)
    }
}
