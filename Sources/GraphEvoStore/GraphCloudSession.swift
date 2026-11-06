import Foundation
import CloudKit
import GraphEvoModel
import OSLog

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
    let invalidateAccount: (@Sendable () -> Void)?
    init(fetch: @escaping @Sendable ([GraphCloudZone]) async throws -> Void,
         cancel: @escaping @Sendable () async throws -> Void,
         send: (@Sendable (GraphCloudOutgoingBatch) async throws -> Void)? = nil,
         forget: (@Sendable (GraphCloudZone) async throws -> Void)? = nil,
         invalidateAccount: (@Sendable () -> Void)? = nil) {
        self.fetch = fetch; self.cancel = cancel; self.send = send; self.forget = forget
        self.invalidateAccount = invalidateAccount
    }
}

/// Captured while the scope is still owned, including failure advice. Never persisted.
struct GraphCloudSendOutcome: Sendable {
    let transportError: (any Error)?
    let retryAfter: TimeInterval?
}

struct GraphCloudAdapter: Sendable {
    var nativeSharing: GraphCloudNativeSharingService? = nil
    var sharing: GraphCloudSharingService? = nil
    var ledger: GraphLedgerService? = nil
    var activation: GraphCloudActivationService? = nil
    let account: @Sendable (String) async throws -> String
    let make: @Sendable (GraphCloudConfiguration, GraphCloudScope, Data?, @escaping @Sendable (GraphCloudEvent) async -> Void) throws -> GraphCloudDriver
    var accountAvailability: (@Sendable (String) async throws -> GraphCloudAccountAvailability)? = nil
    var observeAccount: (@Sendable (@escaping @Sendable () -> Void) -> GraphCloudAccountObservation)? = nil
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
    private let accountSignal: @Sendable (GraphCloudSessionAccountSignal) async -> Void
    private let url: URL
    private var directoryLease: GraphCloudDirectoryLease?
    private var document: GraphCloudDocument
    var activationService: GraphCloudActivationService? { adapter.activation }
    private var joinObservers: [UUID: [UUID: AsyncStream<GraphCloudJoinState>.Continuation]] = [:]
    private var activeJoins = Set<UUID>()
    private var sharingObservers: [GraphID: [UUID: AsyncStream<GraphCloudSharingStatus>.Continuation]] = [:]
    private var ledgerObservers: [GraphID: [UUID: AsyncStream<GraphLedgerStatus>.Continuation]] = [:]
    private var ledgerSignals: [UUID: AsyncStream<Void>.Continuation] = [:]
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
    private struct OutboundRequest {
        let batch: GraphCloudOutgoingBatch
        var reported = Set<String>()
        var sizeRejections = Set<String>()
    }
    private static let sizingLog = Logger(subsystem: "GraphEvo", category: "CloudKitBatch")
    private var outbound: [GraphCloudScope: OutboundRequest] = [:]
    private var drains: [CheckedContinuation<Void, Never>] = []

    private init(configuration: GraphCloudConfiguration, owner: UUID, adapter: GraphCloudAdapter,
                 disk: GraphCloudDisk, lease: GraphCloudDirectoryLease, document: GraphCloudDocument,
                 accountSignal: @escaping @Sendable (GraphCloudSessionAccountSignal) async -> Void) {
        self.configuration = configuration; self.owner = owner; self.adapter = adapter; self.disk = disk
        self.url = configuration.directory.appendingPathComponent("session.json")
        self.directoryLease = lease; self.document = document
        self.accountSignal = accountSignal
    }

    static func open(_ config: GraphCloudConfiguration, adapter: GraphCloudAdapter, disk: GraphCloudDisk = .live, verifiedAccount: String? = nil, ownershipOwner: UUID? = nil, resetAccountState: Bool = false,
                     accountSignal: @escaping @Sendable (GraphCloudSessionAccountSignal) async -> Void = { _ in }) async throws -> GraphCloudSession {
        guard !config.containerIdentifier.isEmpty, config.directory.isFileURL,
              config.maximumEvents > 0, config.maximumBytes > 0 else { throw GraphCloudError.invalidConfiguration }
        let owner = ownershipOwner ?? UUID()
        try await GraphCloudOwnership.shared.acquire(config.containerIdentifier, owner: owner)
        do {
            let account: String
            let availability: GraphCloudAccountAvailability
            if let verifiedAccount { availability = .available(verifiedAccount) }
            else { availability = try await adapter.readAccountAvailability(config.containerIdentifier) }
            switch availability {
            case .available(let value): account = value
            case .signedOut: await accountSignal(.signedOut); throw GraphCloudError.accountUnavailable
            case .restricted: await accountSignal(.restricted); throw GraphCloudError.accountUnavailable
            case .temporarilyUnavailable: await accountSignal(.temporarilyUnavailable); throw GraphCloudError.accountUnavailable
            }
            guard !account.isEmpty else { throw GraphCloudError.accountUnavailable }
            let lease = try GraphCloudDirectoryLease(directory: config.directory)
            let url = config.directory.appendingPathComponent("session.json")
            var doc: GraphCloudDocument
            if let data = try disk.read(url) {
                guard data.count <= config.maximumBytes else { throw GraphCloudError.inboxLimit }
                do { doc = try JSONDecoder().decode(GraphCloudDocument.self, from: data) }
                catch { throw GraphCloudError.invalidState }
                if doc.format == 8, !config.allowsSessionUpgradeFromV8 { throw GraphCloudDiscoveryError.sessionUpgradeRequired }
                guard (doc.format == 8 || doc.format == 9), doc.container == config.containerIdentifier, doc.environment == config.environment else { throw GraphCloudError.invalidState }
                guard doc.account == account else { await accountSignal(.differentAccount); throw GraphCloudError.invalidState }
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
                guard doc.format != 8 || (doc.joins == nil && doc.memberships.allSatisfy { $0.nativePresentationPending == nil }) else { throw GraphCloudError.invalidState }
                let joins = doc.joins ?? []
                guard Set(joins.map(\.id)).count == joins.count,
                      Set(joins.filter { $0.phase != .discarded }.map { $0.invitation.zone }).count == joins.filter({ $0.phase != .discarded }).count else { throw GraphCloudError.invalidState }
                for join in joins { try join.validate() }
                guard Set(doc.sent.map(\.id)).count == doc.sent.count else { throw GraphCloudError.invalidState }
                for receipt in doc.sent {
                    guard doc.bindings.contains(where: { $0.graphID == receipt.graphID && $0.zone == receipt.zone }) else { throw GraphCloudError.invalidState }
                    for record in receipt.saved { try GraphCloudRecordCodec.validateDurable(record) }
                    let route = GraphCloudBinding(zone: receipt.zone, graphID: receipt.graphID)
                    let identity = GraphCloudSessionIdentity(container: doc.container, environment: doc.environment, account: doc.account)
                    for record in receipt.saved where record.assetReference != nil {
                        guard record.assetReference?.identity == identity, record.assetReference?.binding == route else { throw GraphCloudError.invalidState }
                    }
                    for failure in receipt.failures {
                        try Self.validateFailure(failure, zone: receipt.zone)
                        if let reference = failure.serverRecord?.assetReference {
                            guard reference.identity == identity, reference.binding == route else { throw GraphCloudError.invalidState }
                        }
                    }
                }
                for entry in doc.inbox {
                    if let member = doc.memberships.first(where: { $0.role == .participant && $0.binding.zone == entry.change.zone }) {
                        guard entry.membershipGeneration == member.generation else { throw GraphCloudError.invalidState }
                    }
                    try GraphCloudRecordCodec.validateDurable(entry.change)
                    if let reference = entry.change.assetReference {
                        guard reference.identity == GraphCloudSessionIdentity(container: doc.container, environment: doc.environment, account: doc.account),
                              doc.bindings.contains(reference.binding), reference.binding.zone == entry.change.zone else {
                            throw GraphCloudError.invalidState
                        }
                    }
                }
                for receipt in doc.sent {
                    if let member = doc.memberships.first(where: { $0.role == .participant && $0.binding.graphID == receipt.graphID }) {
                        guard receipt.membershipGeneration == member.generation else { throw GraphCloudError.invalidState }
                    }
                }
                guard Set(doc.activations.map { $0.binding.graphID }).count == doc.activations.count else { throw GraphCloudError.invalidState }
                for activation in doc.activations {
                    guard doc.bindings.contains(activation.binding), activation.binding.zone.scope == .private else { throw GraphCloudError.invalidState }
                }
                guard Set(doc.ledgers.map { $0.binding.graphID }).count == doc.ledgers.count else { throw GraphCloudError.invalidState }
                for index in doc.ledgers.indices {
                    let entry = doc.ledgers[index]
                    guard doc.bindings.contains(entry.binding),
                          entry.membershipGeneration == doc.memberships.first(where: { $0.role == .participant && $0.binding == entry.binding })?.generation else { throw GraphCloudError.invalidState }
                    try entry.validate()
                    if let operation = entry.value.current, operation.origin == doc.clientID, !operation.state.terminal {
                        doc.ledgers[index].recoveryRequired = true
                    }
                }
            } else {
                doc = GraphCloudDocument(container: config.containerIdentifier, environment: config.environment, account: account)
                let bytes = try JSONEncoder().encode(doc)
                guard bytes.count <= config.maximumBytes else { throw GraphCloudError.inboxLimit }
                try disk.write(url, bytes)
            }
            if doc.accountResetRequired == true || resetAccountState {
                doc.states.removeAll(); doc.accountResetRequired = false
                try disk.write(url, JSONEncoder().encode(doc))
            }
            let spool = try GraphCloudAssetSpool(root: config.directory.appendingPathComponent("GraphEvoCloudAssets"))
            try await spool.reconcile(retaining: doc.assetReferences)
            for reference in doc.assetReferences {
                try await spool.presence(reference, role: .incoming,
                    identity: GraphCloudSessionIdentity(container: doc.container, environment: doc.environment, account: doc.account),
                    binding: reference.binding, recordName: reference.recordName)
            }
            if doc.format == 8 {
                doc.format = 9
                let encoded = try JSONEncoder().encode(doc)
                guard encoded.count <= config.maximumBytes else { throw GraphCloudError.inboxLimit }
                try disk.write(url, encoded)
            }
            let session = GraphCloudSession(configuration: config, owner: owner, adapter: adapter, disk: disk, lease: lease, document: doc, accountSignal: accountSignal)
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
            try GraphCloudRecordCodec.validateDurable(record)
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
            var remaining = configuration.maximumBytes - data.count - headroom.partialValue
            for ledger in candidate.ledgers {
                let allowance = GraphLedgerReplica.maximumBytes - (try JSONEncoder().encode(ledger).count)
                guard allowance >= 0, allowance <= remaining else { throw GraphCloudError.inboxLimit }
                remaining -= allowance
            }
        }
        do { try disk.write(url, data) } catch { throw GraphCloudError.persistence }
        document = candidate
        publishLedgerObservers()
        for join in candidate.joins ?? [] {
            for observer in joinObservers[join.id]?.values ?? [:].values { observer.yield(join.status) }
        }
        for member in candidate.memberships {
            for observer in sharingObservers[member.binding.graphID]?.values ?? [:].values { observer.yield(member.status) }
        }
    }

    func bindActivation(_ binding: GraphCloudBinding, activationID: UUID, published: Bool, peer: Bool) throws {
        try check()
        if let prior = document.activations.first(where: { $0.binding.graphID == binding.graphID || $0.binding.zone == binding.zone }) {
            guard prior.binding == binding, prior.activationID == activationID, prior.peer == peer else { throw GraphCloudActivationError.authorityConflict }
        } else if document.bindings.contains(where: { $0.graphID == binding.graphID || $0.zone == binding.zone }) {
            throw GraphCloudActivationError.invalidRequest
        }
        var next = document
        if !next.bindings.contains(binding) { next.bindings.append(binding) }
        next.activations.removeAll { $0.binding == binding }
        next.activations.append(.init(binding: binding, activationID: activationID, published: published, peer: peer))
        try publish(next); try enable(.private)
    }
    func activationRoute(for id: GraphID) -> GraphCloudActivationRoute? { document.activations.first { $0.binding.graphID == id } }
    func pruneUnpublishedAssets() async {
        guard let spool = try? GraphCloudAssetSpool(root: configuration.directory.appendingPathComponent("GraphEvoCloudAssets")) else { return }
        try? await spool.reconcile(retaining: document.assetReferences)
    }
    func assetData(for change: GraphCloudIncoming, binding: GraphCloudBinding) async throws -> Data? {
        try check()
        guard let reference = change.assetReference else { return nil }
        let identity = GraphCloudSessionIdentity(container: document.container, environment: document.environment, account: document.account)
        let spool = try GraphCloudAssetSpool(root: configuration.directory.appendingPathComponent("GraphEvoCloudAssets"))
        let data = try await spool.read(reference, role: .incoming, identity: identity,
                                        binding: binding, recordName: change.recordName ?? "")
        try check()
        return data
    }
    var pendingActivationIDs: Set<GraphID> { Set(document.activations.filter { !$0.published }.map { $0.binding.graphID }) }
    func stageActivationSnapshot(_ events: [GraphCloudIncoming], for binding: GraphCloudBinding, activationID: UUID) throws {
        try check()
        guard let route = activationRoute(for: binding.graphID), route.binding == binding,
              route.activationID == activationID, route.peer, !route.published,
              !document.inbox.contains(where: { $0.change.zone == binding.zone }),
              events.allSatisfy({ $0.valid && $0.zone == binding.zone && ($0.kind == .recordChanged || $0.kind == .recordDeleted) && $0.recordType == GraphCloudNodeCodec.recordType }) else {
            throw GraphCloudActivationError.busy
        }
        var next = document
        let spool = try GraphCloudAssetSpool(root: configuration.directory.appendingPathComponent("GraphEvoCloudAssets"))
        let identity = GraphCloudSessionIdentity(container: document.container, environment: document.environment, account: document.account)
        for event in events {
            let frozen = try GraphCloudRecordCodec.freeze(event, identity: identity, binding: binding,
                                                           spool: spool, namespace: activationID)
            try GraphCloudRecordCodec.validateDurable(frozen)
            if let reference = frozen.assetReference {
                try reference.validate(role: .incoming, identity: identity, binding: binding,
                                       recordName: frozen.recordName ?? "")
            }
            next.inbox.append(.init(id: UUID(), change: frozen))
        }
        try publish(next)
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

    func receive(_ received: GraphCloudEvent, scope: GraphCloudScope, driverGeneration: UUID? = nil) async {
        if let driverGeneration, driverGenerations[scope] != driverGeneration { return }
        guard !stopped else { return }
        if case .account(let value) = received {
            if value != document.account {
                await isolateAccount(value == nil ? .signedOut : .differentAccount)
            } else if failure == .accountChanged || failure == .accountUnavailable {
                await accountSignal(.signedIn)
            }
            return
        }
        if case .failure(.accountChanged) = received {
            if failure != .accountChanged { await isolateAccount(.differentAccount) }
            return
        }
        if case .failure(.accountUnavailable) = received {
            block(.accountUnavailable); await accountSignal(.temporarilyUnavailable); return
        }
        var event = received
        if case .incoming(let changes) = event {
            if let failure, failure != .inboxLimit { return }
            let lost = Set(changes.filter {
                $0.valid && $0.zone.scope == scope &&
                ($0.kind == .zoneDeleted || ($0.kind == .recordDeleted && GraphCloudAuthorityCodec.isControl($0)))
            }.map(\.zone))
            if document.activations.contains(where: { lost.contains($0.binding.zone) }) {
                var next = document
                next.activations = next.activations.map { entry in
                    guard lost.contains(entry.binding.zone) else { return entry }
                    return .init(binding: entry.binding, activationID: entry.activationID, published: false, peer: entry.peer)
                }
                do { try publish(next) }
                catch { block(.persistence); return }
            }
            if changes.contains(where: { change in
                GraphLedgerCodec.isControl(change) && change.valid && change.zone.scope == scope &&
                document.ledgers.contains(where: { $0.binding.zone == change.zone })
            }) { signalLedgerControl() }
            event = .incoming(changes.filter { !GraphLedgerCodec.isControl($0) && !GraphCloudAuthorityCodec.isControl($0) })
        }
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
                let candidates = incoming.filter { !removed.contains($0.zone) }
                let spool = try GraphCloudAssetSpool(root: configuration.directory.appendingPathComponent("GraphEvoCloudAssets"))
                let identity = GraphCloudSessionIdentity(container: document.container, environment: document.environment, account: document.account)
                let namespace = UUID()
                let changes = try candidates.map { change -> GraphCloudIncoming in
                    guard change.kind == .recordChanged, let archive = change.recordArchive,
                          let record = try? GraphCloudRecordCodec.restore(archive), record["asset"] != nil else { return change }
                    guard let binding = document.bindings.first(where: { $0.zone == change.zone }) else { throw GraphCloudError.invalidState }
                    return try GraphCloudRecordCodec.freeze(change, identity: identity, binding: binding,
                                                            spool: spool, namespace: namespace)
                }
                guard changes.allSatisfy({ $0.valid && $0.zone.scope == scope }) else { throw GraphCloudError.invalidState }
                for change in changes {
                    try GraphCloudRecordCodec.validateDurable(change)
                    if let reference = change.assetReference {
                        guard let binding = document.bindings.first(where: { $0.zone == change.zone }) else {
                            throw GraphCloudError.invalidState
                        }
                        try reference.validate(role: .incoming, identity: identity, binding: binding,
                                               recordName: change.recordName ?? "")
                    }
                }
                guard changes.count <= configuration.maximumEvents - document.eventCount else { throw GraphCloudError.inboxLimit }
                var next = document
                next.inbox += changes.compactMap { change in
                    let member = next.memberships.first { $0.binding.zone == change.zone && $0.role == .participant }
                    return GraphCloudInboxEntry(id: UUID(), change: change, membershipGeneration: member?.generation)
                }
                if !changes.isEmpty { try publish(next, reservingControl: true) }
            case .sent(var receipt):
                guard let batch = outbound[scope]?.batch, receipt.batchID == batch.id, receipt.graphID == batch.graphID,
                      receipt.zone == batch.zone, receipt.zone.scope == scope else { throw GraphCloudError.invalidState }
                let member = document.memberships.first { $0.binding.graphID == receipt.graphID && $0.role == .participant }
                if member?.terminal == true { return }
                let items = Dictionary(uniqueKeysWithValues: batch.items.map { ($0.recordName, $0.change.operation) })
                let names = receipt.saved.compactMap(\.recordName) + receipt.deletedNames + receipt.failures.map(\.recordName)
                if names.isEmpty { return }
                guard Set(names).count == names.count, outbound[scope]!.reported.isDisjoint(with: names),
                      receipt.saved.allSatisfy({ $0.kind == .recordChanged && $0.zone == batch.zone && $0.recordName.flatMap { items[$0] } == .save }),
                      receipt.deletedNames.allSatisfy({ items[$0] == .delete }),
                      receipt.failures.allSatisfy({ items[$0.recordName] != nil }) else { throw GraphCloudError.invalidState }
                outbound[scope]!.reported.formUnion(names)
                var finalFailures = receipt.failures
                if batch.items.count > 1 {
                    // Size failures can be retried with a smaller request. Persist the other results now.
                    finalFailures.removeAll { failure in
                        guard failure.code == CKError.Code.limitExceeded.rawValue, failure.serverRecord == nil else { return false }
                        outbound[scope]!.sizeRejections.insert(failure.recordName)
                        return true
                    }
                    if receipt.saved.isEmpty, receipt.deletedNames.isEmpty, finalFailures.isEmpty { return }
                }
                let route = GraphCloudBinding(zone: receipt.zone, graphID: receipt.graphID)
                let identity = GraphCloudSessionIdentity(container: document.container, environment: document.environment, account: document.account)
                let spool = try GraphCloudAssetSpool(root: configuration.directory.appendingPathComponent("GraphEvoCloudAssets"))
                let saved = try receipt.saved.map { try GraphCloudRecordCodec.freeze($0, identity: identity,
                    binding: route, spool: spool, namespace: receipt.id) }
                let failures = try finalFailures.map { failure -> GraphCloudRecordFailure in
                    let server = try failure.serverRecord.map { try GraphCloudRecordCodec.freeze($0, identity: identity,
                        binding: route, spool: spool, namespace: receipt.id) }
                    return GraphCloudRecordFailure(recordName: failure.recordName, code: failure.code, serverRecord: server)
                }
                receipt = GraphCloudSentReceipt(id: receipt.id, batchID: receipt.batchID, graphID: receipt.graphID,
                    zone: receipt.zone, saved: saved, deletedNames: receipt.deletedNames, failures: failures)
                for record in receipt.saved {
                    try GraphCloudRecordCodec.validateDurable(record)
                    if let reference = record.assetReference {
                        try reference.validate(role: .incoming, identity: identity, binding: route,
                                               recordName: record.recordName ?? "")
                    }
                }
                for failure in receipt.failures {
                    try Self.validateFailure(failure, zone: receipt.zone)
                    if let reference = failure.serverRecord?.assetReference {
                        try reference.validate(role: .incoming, identity: identity, binding: route,
                                               recordName: failure.recordName)
                    }
                }
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

    private func isolateAccount(_ signal: GraphCloudSessionAccountSignal) async {
        for driver in drivers.values { driver.invalidateAccount?() }
        block(.accountChanged)
        await accountSignal(signal)
        var next = document
        next.states.removeAll(); next.accountResetRequired = true
        do { try publish(next) }
        catch { failure = .persistence }
    }
    func suspendForUnavailableAccount() { block(.accountUnavailable) }
    func retainedBindings() -> [GraphCloudBinding] { document.bindings }
    func retainedIdentity() -> GraphCloudSessionIdentity {
        .init(container: document.container, environment: document.environment, account: document.account)
    }

    private func block(_ error: GraphCloudError) {
        guard failure == nil || (failure == .inboxLimit && error != .inboxLimit) ||
                (failure == .accountUnavailable && error == .accountChanged) else { return }
        failure = error
        if error != .inboxLimit {
            for values in ledgerObservers.values {
                for value in values.values {
                    value.yield(.init(ledger: nil, remote: nil, state: .unavailable,
                        failure: "The cloud session is unavailable.", confirmedRevision: nil))
                    value.finish()
                }
            }
            ledgerObservers.removeAll()
        }
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
        let blocked = Set(document.activations.filter { !$0.published }.map { $0.binding.zone })
        let permitted = zones.filter { !blocked.contains($0) && (selected?.contains($0) ?? true) }
        if permitted.isEmpty && !zones.isEmpty { return }
        try await driver.fetch(permitted)
        if let failure { throw failure }
    }

    /// Control operations share the engine scope gate and participate in session stop draining.
    private func control<Value: Sendable>(_ scope: GraphCloudScope, allowingDataLimit: Bool = false,
        body: @Sendable (GraphCloudSharingService, String) async throws -> Value) async throws -> Value {
        guard let sharing = adapter.sharing else { throw GraphCloudSharingError.unavailable }
        return try await withScopeControl(scope, allowingDataLimit: allowingDataLimit) { session in
            try await body(sharing, session.document.account)
        }
    }

    func withScopeControl<Value: Sendable>(_ scope: GraphCloudScope, allowingDataLimit: Bool = false,
        body: @Sendable (isolated GraphCloudSession) async throws -> Value) async throws -> Value {
        try check(control: allowingDataLimit)
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        fetches += 1
        defer {
            activeFetches.remove(scope); fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        let result = try await body(self)
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

    func sendWithAdvice(_ batch: GraphCloudOutgoingBatch, activationPermit: UUID? = nil) async throws -> GraphCloudSendOutcome {
        try check()
        let scope = batch.zone.scope
        if let activation = activationRoute(for: batch.graphID), !activation.published {
            guard !activation.peer, activation.activationID == activationPermit else { throw GraphCloudActivationError.recoveryRequired }
        }
        guard let send = drivers[scope]?.send else { throw GraphCloudError.transportUnavailable }
        guard document.bindings.contains(where: { $0.zone == batch.zone && $0.graphID == batch.graphID }) else { throw GraphCloudError.invalidState }
        guard activeFetches.insert(scope).inserted else { throw GraphCloudError.busy }
        retryAdvice[scope] = nil
        fetches += 1
        defer {
            outbound.removeValue(forKey: scope); activeFetches.remove(scope); fetches -= 1
            if fetches == 0 { let values = drains; drains.removeAll(); for value in values { value.resume() } }
        }
        do {
            let requests = try GraphCloudBatchSizing.requests(for: batch)
            for items in requests.isEmpty ? [[]] : requests {
                try await sendRequest(items, from: batch, send: send)
            }
            return GraphCloudSendOutcome(transportError: nil, retryAfter: retryAdvice[scope])
        } catch {
            return GraphCloudSendOutcome(transportError: error, retryAfter: retryAdvice[scope])
        }
    }
    private func sendRequest(_ items: [GraphCloudOutgoingNode], from attempt: GraphCloudOutgoingBatch,
                             send: @Sendable (GraphCloudOutgoingBatch) async throws -> Void) async throws {
        try check()
        try Task.checkCancellation()
        let scope = attempt.zone.scope
        guard !document.memberships.contains(where: {
            $0.binding.graphID == attempt.graphID && $0.role == .participant && $0.terminal
        }) else { throw GraphCloudError.zoneUnavailable }
        let batch = GraphCloudOutgoingBatch(id: attempt.id, graphID: attempt.graphID, zone: attempt.zone,
                                           items: items, assetRoot: attempt.assetRoot)
        if items.count == 1, let item = items.first {
            let bytes = try GraphCloudBatchSizing.estimate(item, zone: batch.zone)
            if bytes > GraphCloudBatchSizing.recordWarning {
                Self.sizingLog.warning("CloudKit record \(item.recordName, privacy: .private) is approximately \(bytes) bytes without assets. Sending separately.")
            }
        }

        outbound[scope] = OutboundRequest(batch: batch)
        var error: (any Error)?
        do { try await send(batch) } catch let caught { error = caught }
        try check()
        let request = outbound[scope]!
        let native = error.map { $0 as NSError }
        let code = native?.domain == CKErrorDomain ? native?.code : nil
        let wholeRequestExceeded = code == CKError.Code.limitExceeded.rawValue
        let reportedPartial = code == CKError.Code.partialFailure.rawValue && request.reported.count == items.count
        if let error, !wholeRequestExceeded && !(reportedPartial && !request.sizeRejections.isEmpty) { throw error }

        let retry = items.filter {
            request.sizeRejections.contains($0.recordName) ||
                (wholeRequestExceeded && !request.reported.contains($0.recordName))
        }
        if retry.isEmpty {
            if items.isEmpty, let error { throw error }
            return
        }
        if items.count == 1, let item = retry.first {
            await receive(.sent(GraphCloudSentReceipt(batchID: batch.id, graphID: batch.graphID, zone: batch.zone,
                saved: [], deletedNames: [], failures: [.init(recordName: item.recordName, code: CKError.Code.limitExceeded.rawValue)])),
                scope: scope)
            try check()
            return
        }
        let middle = (retry.count + 1) / 2
        try await sendRequest(Array(retry.prefix(middle)), from: attempt, send: send)
        if middle < retry.count {
            try await sendRequest(Array(retry.dropFirst(middle)), from: attempt, send: send)
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
        let descriptors = document.inbox.filter { $0.change.zone == zone && GraphCloudGraphDescriptor.isControl($0.change) }
        let permissions = Array(controls.prefix(limit))
        let selected = permissions + descriptors.prefix(limit - permissions.count)
        let application = document.inbox.lazy.filter { $0.change.zone == zone && !GraphCloudShareControl.isControl($0.change) && !GraphCloudGraphDescriptor.isControl($0.change) }
        return selected + application.prefix(limit - selected.count)
    }
    func retainedReceiptIDs(for graph: GraphID) throws -> Set<UUID> {
        try check()
        let zones = Set(document.bindings.filter { $0.graphID == graph }.map(\.zone))
        return Set(document.inbox.filter { zones.contains($0.change.zone) }.map(\.id))
            .union(document.sent.filter { $0.graphID == graph }.map(\.id))
    }
    func consume(_ ids: Set<UUID>) async throws {
        try check()
        let prior = document.assetReferences
        var next = document
        next.inbox.removeAll { ids.contains($0.id) }; next.sent.removeAll { ids.contains($0.id) }
        do { try publish(next) } catch { block(error as? GraphCloudError ?? .persistence); throw error }
        if !prior.isEmpty, let spool = try? GraphCloudAssetSpool(root: configuration.directory.appendingPathComponent("GraphEvoCloudAssets")) {
            await spool.remove(prior, retaining: next.assetReferences)
        }
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
        try check(control: true)
        guard limit > 0 else { throw GraphCloudError.invalidConfiguration }
        return Array(document.inbox.prefix(limit))
    }
    func containsBinding(for id: GraphID) -> Bool { document.bindings.contains { $0.graphID == id } }

    func binding(for zone: GraphCloudZone) -> GraphCloudBinding? { document.bindings.first { $0.zone == zone } }

    func stop() async throws {
        if let stopping { return try await stopping.value }
        if stopped { return }
        let job = Task {
            try await self.cancelForStop()
            await self.finishStop()
        }
        stopping = job
        try await job.value
    }

    private func cancelForStop() async throws {
        if let cancellation { try await cancellation.value }
        else { try await Self.cancelAll(Array(drivers.values)) }
        cancellation = nil
    }

    private func finishStop() async {
        if fetches > 0 { await withCheckedContinuation { drains.append($0) } }
        stopped = true
        drivers.removeAll(); driverGenerations.removeAll(); directoryLease = nil
        for values in joinObservers.values { for value in values.values { value.finish() } }; joinObservers.removeAll()
        for values in sharingObservers.values { for value in values.values { value.finish() } }; sharingObservers.removeAll()
        for values in ledgerObservers.values { for value in values.values { value.finish() } }; ledgerObservers.removeAll()
        for value in ledgerSignals.values { value.finish() }; ledgerSignals.removeAll()
        await GraphCloudOwnership.shared.release(configuration.containerIdentifier, owner: owner)
    }
}

extension GraphCloudSession {
    private func acceptsDriver(_ scope: GraphCloudScope, generation: UUID) -> Bool { driverGenerations[scope] == generation }

    private func verifySharingAccount(_ expected: String) async throws {
        let actual: String
        switch try await adapter.readAccountAvailability(configuration.containerIdentifier) {
        case .available(let account): actual = account
        case .signedOut: await isolateAccount(.signedOut); throw GraphCloudError.accountChanged
        case .restricted:
            block(.accountUnavailable); await accountSignal(.restricted); throw GraphCloudError.accountUnavailable
        case .temporarilyUnavailable:
            block(.accountUnavailable); await accountSignal(.temporarilyUnavailable); throw GraphCloudError.accountUnavailable
        }
        guard actual == expected else { await isolateAccount(.differentAccount); throw GraphCloudError.accountChanged }
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
    func beginMembership(_ binding: GraphCloudBinding, storeID: String, shareIdentity: String, generation: UUID? = nil) async throws -> GraphCloudMembership {
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
        let member = GraphCloudMembership(binding: binding, identity: try identity(), generation: generation ?? UUID(), role: .participant,
            phase: .joining, permission: nil, storeID: storeID, shareIdentity: shareIdentity)
        var next = document; next.memberships.removeAll { $0.binding.graphID == binding.graphID }; next.memberships.append(member)
        next.inbox.removeAll { $0.change.zone == binding.zone }
        next.sent.removeAll { $0.graphID == binding.graphID }
        next.ledgers.removeAll { $0.binding.graphID == binding.graphID }
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
            membership: membership, inbox: document.inbox.filter { $0.change.zone == zone }, receipts: document.sent.filter { $0.graphID == id }, ledger: document.ledgers.first { $0.binding.graphID == id })
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
            current.shareIdentity = nil; current.nativePresentationPending = nil
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
        next.ledgers.removeAll { $0.binding.graphID == id }
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

extension GraphCloudSession {
    var ledgerClientID: UUID { document.clientID }
    func ledgerService() throws -> GraphLedgerService {
        guard let service = adapter.ledger else { throw GraphLedgerError.unavailable }
        return service
    }
    func verifyLedgerAccount() async throws { try await verifySharingAccount(document.account) }
    private func ledgerBinding(_ id: GraphID, writing: Bool) throws -> GraphCloudBinding {
        try check(control: true)
        guard let binding = document.bindings.first(where: { $0.graphID == id }) else { throw GraphLedgerError.unavailable }
        if binding.zone.scope == .shared {
            guard document.memberships.contains(where: { $0.role == .participant && $0.binding == binding }) else { throw GraphLedgerError.unavailable }
        }
        if let member = document.memberships.first(where: { $0.binding.graphID == id && $0.role == .participant }) {
            guard !member.terminal, member.hadAccess else { throw GraphLedgerError.unavailable }
            if writing, member.permission != .readWrite { throw GraphLedgerError.readOnly }
        }
        return binding
    }
    func ensureLedger(_ id: GraphID, writing: Bool) throws -> GraphLedgerReplica {
        let binding = try ledgerBinding(id, writing: writing)
        if let existing = document.ledgers.first(where: { $0.binding.graphID == id }) { return existing }
        let member = document.memberships.first { $0.role == .participant && $0.binding == binding }
        let entry = GraphLedgerReplica(generation: UUID(), binding: binding, membershipGeneration: member?.generation, value: .empty(id))
        var next = document; next.ledgers.append(entry)
        try entry.validate(); try publish(next, reservingControl: true)
        signalLedgerControl(); return entry
    }
    func checkedLedger(_ id: GraphID, generation: UUID) throws -> GraphLedgerReplica {
        let binding = try ledgerBinding(id, writing: false)
        guard let entry = document.ledgers.first(where: { $0.binding == binding && $0.generation == generation }),
              entry.membershipGeneration == document.memberships.first(where: { $0.role == .participant && $0.binding == binding })?.generation else {
            throw GraphLedgerError.unavailable
        }
        return entry
    }
    func saveLedger(_ entry: GraphLedgerReplica, signal: Bool) throws {
        _ = try checkedLedger(entry.binding.graphID, generation: entry.generation)
        try entry.validate()
        var next = document
        next.ledgers.removeAll { $0.binding.graphID == entry.binding.graphID }; next.ledgers.append(entry)
        try publish(next, reservingControl: true)
        if signal { signalLedgerControl() }
    }
    func requireLedgerUpload(_ id: GraphID) throws {
        _ = try ledgerBinding(id, writing: true)
        if let member = document.memberships.first(where: { $0.binding.graphID == id && $0.role == .participant }) {
            guard member.phase == .active else { throw GraphLedgerError.unavailable }
        }
    }
    func ledgerStatus(_ id: GraphID) throws -> GraphLedgerStatus {
        try ensureLedger(id, writing: false).status
    }
    func enabledLedgerIDs(in scope: GraphCloudScope? = nil) throws -> [GraphID] {
        try check(control: true)
        return document.ledgers.filter { entry in
            (scope == nil || entry.binding.zone.scope == scope) &&
            !document.memberships.contains(where: { $0.binding.graphID == entry.binding.graphID && $0.terminal })
        }.map { $0.binding.graphID }
    }
    func ledgerGeneration(_ id: GraphID) throws -> UUID? {
        _ = try ledgerBinding(id, writing: false)
        return document.ledgers.first { $0.binding.graphID == id }?.generation
    }
    func recordLedgerFailure(_ id: GraphID, generation: UUID, error: any Error) throws {
        var next = try checkedLedger(id, generation: generation)
        let native = error as NSError
        next.failure = native.domain == "CKErrorDomain" ? "Cloud control request failed (code \(native.code))." : "Graph control request failed: \(String(describing: error as? GraphLedgerError ?? .unavailable))."
        try saveLedger(next, signal: false)
    }
    func observeLedger(_ id: GraphID) throws -> AsyncStream<GraphLedgerStatus> {
        let status = try ledgerStatus(id), token = UUID()
        let pair = AsyncStream<GraphLedgerStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ledgerObservers[id, default: [:]][token] = pair.continuation
        pair.continuation.yield(status)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeLedgerObserver(id, token: token) } }
        return pair.stream
    }
    private func removeLedgerObserver(_ id: GraphID, token: UUID) { ledgerObservers[id]?.removeValue(forKey: token) }
    private func publishLedgerObservers() {
        for id in Array(ledgerObservers.keys) {
            let unavailable = document.memberships.contains { $0.binding.graphID == id && $0.terminal }
            if unavailable {
                let values = ledgerObservers.removeValue(forKey: id) ?? [:]
                for value in values.values {
                    value.yield(.init(ledger: nil, remote: nil, state: .unavailable, failure: nil, confirmedRevision: nil)); value.finish()
                }
            } else if let entry = document.ledgers.first(where: { $0.binding.graphID == id }) {
                for value in ledgerObservers[id]?.values ?? [:].values { value.yield(entry.status) }
            }
        }
    }
    func ledgerSignalFeed() throws -> GraphLedgerSignalFeed {
        try check(control: true)
        let token = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ledgerSignals[token] = pair.continuation; pair.continuation.yield(())
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeLedgerSignal(token) } }
        return GraphLedgerSignalFeed(stream: pair.stream, cancel: { [weak self] in
            pair.continuation.finish()
            Task { await self?.removeLedgerSignal(token) }
        })
    }
    private func removeLedgerSignal(_ token: UUID) { ledgerSignals.removeValue(forKey: token) }
    private func signalLedgerControl() { for value in ledgerSignals.values { value.yield(()) } }
}

extension GraphCloudSession {
    func nativePrepareShare(_ binding: GraphCloudBinding, title: String) async throws -> Data {
        try check()
        guard document.bindings.contains(binding), binding.zone.scope == .private,
              let service = adapter.nativeSharing else { throw GraphCloudSharingError.ownerRequired }
        guard !activeFetches.contains(.private) else { throw GraphCloudError.busy }
        let operation = UUID(), config = configuration
        shareCreation = operation
        defer { if shareCreation == operation { shareCreation = nil } }
        let mayCreate = !document.shareAttempts.contains(binding.zone)
        return try await nativeControl(.private) { session in
            let result = try await service.prepare(config, binding, title, mayCreate) {
                try await self.recordShareCreation(binding, operation: operation)
            }
            return result
        }
    }

    func nativeBeginJoin(_ url: URL) async throws -> GraphCloudJoinIntent {
        try Task.checkCancellation()
        try check(control: true)
        guard let service = adapter.nativeSharing else { throw GraphCloudSharingError.unavailable }
        let config = configuration, account = document.account
        let invitation = try await nativeControl(.shared, allowingDataLimit: true) { _ in
            try await service.inspect(config, url, account)
        }
        try Task.checkCancellation()
        if let prior = (document.joins ?? []).first(where: { $0.invitation.zone == invitation.zone && $0.phase != .discarded }) {
            guard prior.invitation.url == invitation.url else { throw GraphCloudDiscoveryError.invalidInvitation }
            if prior.phase == .joined, let id = prior.graphID,
               let member = try membership(id), member.phase == .removed, member.pending == nil {
                var retired = prior; retired.phase = .discarded; try updateJoin(retired)
            } else { return prior }
        }
        guard !document.bindings.contains(where: { $0.zone == invitation.zone }) else { throw GraphCloudError.ownershipConflict }
        let value = GraphCloudJoinIntent(id: UUID(), invitation: invitation)
        try value.validate(); try updateJoin(value)
        return value
    }
    func nativeJoins() throws -> [GraphCloudJoinIntent] { try check(control: true); return document.joins ?? [] }
    func nativeJoin(_ id: UUID) throws -> GraphCloudJoinIntent {
        try check(control: true)
        guard let join = (document.joins ?? []).first(where: { $0.id == id }) else { throw GraphCloudDiscoveryError.invalidJoin }
        return join
    }
    func updateJoin(_ value: GraphCloudJoinIntent, expectedPhase: GraphCloudJoinState.Phase? = nil) throws {
        try check(control: true); try value.validate()
        var next = document, joins = next.joins ?? []
        if let index = joins.firstIndex(where: { $0.id == value.id }) {
            let previous = joins[index]
            if let expectedPhase, previous.phase != expectedPhase { throw GraphCloudDiscoveryError.busy }
            guard previous.invitation == value.invitation,
                  previous.graphID == nil || previous.graphID == value.graphID else { throw GraphCloudDiscoveryError.invalidJoin }
            joins[index] = value
        } else { joins.append(value) }
        next.joins = joins; try publish(next)
    }
    func nativeAdvanceJoin(_ id: UUID) async throws {
        try check(control: true)
        guard activeJoins.insert(id).inserted else { throw GraphCloudDiscoveryError.busy }
        defer { activeJoins.remove(id) }
        var join = try nativeJoin(id)
        guard ![.joined, .discarded].contains(join.phase) else { return }
        guard let service = adapter.nativeSharing else { throw GraphCloudSharingError.unavailable }
        let config = configuration, account = document.account, invitation = join.invitation
        do {
            if join.phase == .discarding {
                try await nativeControl(.shared, allowingDataLimit: true) { _ in
                    try await service.discard(config, invitation, account)
                }
                join.phase = .discarded; join.failure = false; try updateJoin(join); return
            }
            guard join.phase != .openingReplica else { throw GraphCloudDiscoveryError.invalidJoin }
            try await nativeControl(.shared, allowingDataLimit: true) { _ in
                try await service.accept(config, invitation, account)
            }
            join.phase = .discoveringGraph; join.failure = false; try updateJoin(join)
            let graphID = try await nativeControl(.shared, allowingDataLimit: true) { _ in
                try await service.discover(config, invitation.zone)
            }
            guard join.graphID == nil || join.graphID == graphID,
                  !document.bindings.contains(where: { ($0.graphID == graphID || $0.zone == join.invitation.zone) && $0 != .init(zone: join.invitation.zone, graphID: graphID) }) else {
                throw GraphCloudError.ownershipConflict
            }
            join.graphID = graphID; join.phase = .ready; join.failure = false; try updateJoin(join)
        } catch {
            join.failure = true
            try updateJoin(join)
            // The durable intent is queryable even if native acceptance already committed.
            throw error
        }
    }
    func nativeDiscardJoin(_ id: UUID) async throws {
        var join = try nativeJoin(id)
        guard !activeJoins.contains(id), ![.openingReplica, .joined].contains(join.phase) else { throw GraphCloudDiscoveryError.busy }
        if join.phase == .discarded { return }
        join.phase = .discarding; try updateJoin(join)
        try await nativeAdvanceJoin(id)
    }
    func observeJoin(_ id: UUID) throws -> AsyncStream<GraphCloudJoinState> {
        let value = try nativeJoin(id), token = UUID()
        let pair = AsyncStream<GraphCloudJoinState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        joinObservers[id, default: [:]][token] = pair.continuation
        pair.continuation.yield(value.status)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeJoinObserver(id, token: token) } }
        return pair.stream
    }
    private func removeJoinObserver(_ id: UUID, token: UUID) { joinObservers[id]?.removeValue(forKey: token) }
}

extension GraphCloudSession {
    func nativeRecordOwnerShare(_ binding: GraphCloudBinding, archive: Data) throws {
        guard let share = try GraphCloudRecordCodec.restore(archive) as? CKShare, let url = share.url else { throw GraphCloudDiscoveryError.metadataPending }
        var member = try membership(binding.graphID) ?? GraphCloudMembership(binding: binding, identity: identity(),
            generation: UUID(), role: .owner, phase: .active, permission: .readWrite, hadAccess: true)
        guard member.role == .owner, member.pending == nil else { throw GraphCloudError.busy }
        member.shareIdentity = GraphCloudShareIdentity.of(url); member.nativePresentationPending = true
        try updateMembership(member)
    }
    func nativeReconcileOwnerShare(_ binding: GraphCloudBinding, stopped: Bool) async throws {
        guard var member = try membership(binding.graphID), member.role == .owner else { throw GraphCloudSharingError.ownerRequired }
        let snapshot = try await inspectSharing(binding)
        if let snapshot {
            guard snapshot.role == .owner else { throw GraphCloudSharingError.ownerRequired }
            member.shareIdentity = snapshot.identity; member.failure = nil; member.nativePresentationPending = nil
            try updateMembership(member)
        } else {
            guard stopped || (member.nativePresentationPending == true && member.shareIdentity != nil) else { throw GraphCloudSharingError.metadataPending }
            member.shareIdentity = nil; member.failure = nil; member.nativePresentationPending = nil
            var next = document
            next.shareAttempts.removeAll { $0 == binding.zone }
            next.memberships.removeAll { $0.binding.graphID == binding.graphID }; next.memberships.append(member)
            try publish(next)
        }
    }
}

extension GraphCloudSession {
    func verifyNativeJoinDescriptor(_ id: UUID) async throws {
        let join = try nativeJoin(id)
        guard let service = adapter.nativeSharing, let expected = join.graphID else { throw GraphCloudDiscoveryError.invalidJoin }
        let config = configuration
        let actual = try await nativeControl(.shared) { _ in try await service.discover(config, join.invitation.zone) }
        guard actual == expected else { throw GraphCloudDiscoveryError.invalidDescriptor }
    }
}

extension GraphCloudSession {
    func nativeBindAcceptedJoin(_ id: UUID) async throws -> GraphCloudParticipantAccess {
        let join = try nativeJoin(id)
        guard let graphID = join.graphID, join.phase == .openingReplica,
              let service = adapter.nativeSharing, let member = try membership(graphID),
              member.generation == id, !member.terminal else { throw GraphCloudDiscoveryError.invalidJoin }
        let config = configuration, account = document.account
        let current = try await nativeControl(.shared) { _ in try await service.inspect(config, join.invitation.url, account) }
        guard current.accepted, current.zone == join.invitation.zone, current.url == join.invitation.url else {
            throw GraphCloudDiscoveryError.invalidInvitation
        }
        let binding = GraphCloudBinding(zone: current.zone, graphID: graphID)
        try bind(binding)
        var updated = member; updated.permission = current.permission
        try updateMembership(updated)
        return .init(binding: binding, account: account, permission: current.permission, accepted: true,
                     identity: try identity(), generation: id)
    }
}

extension GraphCloudSession {
    private func nativeControl<Value: Sendable>(_ scope: GraphCloudScope, allowingDataLimit: Bool = false,
        body: @Sendable (isolated GraphCloudSession) async throws -> Value) async throws -> Value {
        try await withScopeControl(scope, allowingDataLimit: allowingDataLimit) { session in
            try await session.verifyLedgerAccount()
            let value = try await body(session)
            try await session.verifyLedgerAccount()
            return value
        }
    }
}
