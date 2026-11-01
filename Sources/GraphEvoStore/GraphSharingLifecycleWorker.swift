import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// One finite control worker per database scope. Durable intents remain in the session document.
actor GraphSharingLifecycleWorker {
    private let inventory: @Sendable () async -> [GraphID]
    private let step: @Sendable (GraphID) async -> (any Error)?
    private let generation: (@Sendable (GraphID) async -> UUID?)?
    private var generations: [GraphID: UUID] = [:]
    private let clock: GraphAutomaticClock
    private let retryPermission: Bool
    private var active = false
    private var revision: UInt64 = 0
    private var job: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var deadlines: [GraphID: Double] = [:]
    private var waiting = Set<GraphID>()
    private var blocked = Set<GraphID>()
    private var failures: [GraphID: Int] = [:]
    private var explicit: Set<GraphID> = []
    init(clock: GraphAutomaticClock, retryPermission: Bool = false,
         generation: (@Sendable (GraphID) async -> UUID?)? = nil, inventory: @escaping @Sendable () async -> [GraphID],
         step: @escaping @Sendable (GraphID) async -> (any Error)?) {
        self.clock = clock; self.retryPermission = retryPermission; self.generation = generation; self.inventory = inventory; self.step = step
    }
    func setActive(_ value: Bool, revision: UInt64) {
        guard revision >= self.revision else { return }
        self.revision = revision
        if value && !active {
            for id in deadlines.keys where !waiting.contains(id) && !blocked.contains(id) { deadlines[id] = clock.now() }
        }
        active = value
        if value { pump() } else { timer?.cancel(); timer = nil }
    }
    func request(_ ids: [GraphID] = [], explicit: Bool = false) {
        for id in ids {
            if explicit, blocked.remove(id) != nil { waiting.remove(id) }
            if !waiting.contains(id), !blocked.contains(id) { self.explicit.insert(id); deadlines[id] = clock.now() }
        }
        pump()
    }
    func shutdown() async {
        active = false; timer?.cancel(); timer = nil
        let current = job; await current?.value
    }
    private func pump() {
        guard active, job == nil else { return }
        timer?.cancel(); timer = nil
        job = Task { [weak self] in await self?.run() }
    }
    private func run() async {
        let ids = await inventory(), now = clock.now()
        let retained = Set(ids)
        for id in Set(deadlines.keys).union(blocked).union(waiting).union(explicit).union(generations.keys).subtracting(retained) {
            forget(id)
        }
        for id in ids.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard active else { break }
            let currentGeneration: UUID?
            if let generation {
                currentGeneration = await generation(id)
                guard active else { break }
                guard let currentGeneration else { forget(id); continue }
                if generations[id] != currentGeneration {
                    forget(id); generations[id] = currentGeneration; deadlines[id] = clock.now()
                }
            } else { currentGeneration = nil }
            let requested = explicit.remove(id) != nil
            guard (deadlines[id] ?? now) <= clock.now() || requested else { continue }
            let error = await step(id)
            if let generation, await generation(id) != currentGeneration {
                // A replacement participation must not inherit an admitted old turn's result.
                forget(id); deadlines[id] = clock.now(); continue
            }
            if let error { applyFailure(id, error: error) } else { recordSuccess(id) }
        }
        job = nil
        guard active else { return }
        let next = min(deadlines.values.min() ?? clock.now() + 60, clock.now() + 60)
        timer = Task { [weak self, clock] in
            do { try await clock.sleep(next); try Task.checkCancellation(); await self?.wake() } catch {}
        }
    }
    private func forget(_ id: GraphID) {
        deadlines.removeValue(forKey: id); generations.removeValue(forKey: id)
        waiting.remove(id); blocked.remove(id); explicit.remove(id); failures.removeValue(forKey: id)
    }
    var diagnosticIdle: Bool { job == nil }
    func retryDeadline(_ id: GraphID) -> Double? { deadlines[id] }
    func recordFailure(_ id: GraphID, error: any Error) {
        applyFailure(id, error: error); pump()
    }
    func recordSuccess(_ id: GraphID) {
        waiting.remove(id); blocked.remove(id); failures[id] = 0
        // A signal received during the admitted turn belongs to the next turn.
        deadlines[id] = clock.now() + (explicit.contains(id) ? 0 : 60)
    }
    private func applyFailure(_ id: GraphID, error: any Error) {
        explicit.remove(id)
        waiting.insert(id)
        if error as? GraphCloudError == .busy || error as? GraphSyncError == .busy || GraphLocalAdmission.isReserved(error) {
            deadlines[id] = clock.now() + 1
        } else {
            let native = error as NSError
            let retryable = (native.domain == "CKErrorDomain" && ([3,4,6,7,23].contains(native.code) || retryPermission && native.code == 10)) ||
                native.domain == NSURLErrorDomain || error as? GraphCloudSharingError == .metadataPending || error as? GraphCloudError == .zoneUnavailable
            if retryable {
                let n = failures[id, default: 0], delays: [Double] = [5,15,30,60,120,300]
                let delay = min(300, delays[min(n,5)] * min(1.2,max(0.8,clock.jitter())))
                deadlines[id] = clock.now() + max(delay, native.userInfo[CKErrorRetryAfterKey] as? Double ?? 0)
                failures[id] = n + 1
            } else { deadlines[id] = .infinity; blocked.insert(id) }
        }
    }
    private func wake() { timer = nil; pump() }
}

extension GraphContextManager {
    func setSharingLifecycleActive(_ active: Bool, revision: UInt64, configuration: GraphCloudConfiguration,
        clock: GraphAutomaticClock) async {
        for scope in [GraphCloudScope.private, .shared] {
            let key = configuration.namespace + ":" + scope.rawValue
            if lifecycleWorkers[key] == nil {
                lifecycleWorkers[key] = GraphSharingLifecycleWorker(clock: clock, inventory: { [weak self] in
                    guard let self, let session = try? await self.cloud(configuration), let members = try? await session.memberships() else { return [] }
                    return members.filter { $0.binding.zone.scope == scope && ($0.pending != nil || $0.role == .participant && $0.phase != .removed) }.map { $0.binding.graphID }
                }, step: { [weak self] id in
                    guard let self else { return GraphCloudError.stopped }
                    return await self.sharingLifecycleStep(id, configuration: configuration)
                })
            }
            await lifecycleWorkers[key]?.setActive(active, revision: revision)
        }
    }
    func stopSharingLifecycle(_ configuration: GraphCloudConfiguration) async {
        for scope in [GraphCloudScope.private, .shared] {
            let key = configuration.namespace + ":" + scope.rawValue
            if let worker = lifecycleWorkers.removeValue(forKey: key) { await worker.shutdown() }
        }
    }
    func requestSharingLifecycle(_ configuration: GraphCloudConfiguration, ids: [GraphID], explicit: Bool) async {
        for scope in [GraphCloudScope.private, .shared] {
            await lifecycleWorkers[configuration.namespace + ":" + scope.rawValue]?.request(ids, explicit: explicit)
        }
    }
    func sharingLifecycleStep(_ id: GraphID, configuration: GraphCloudConfiguration) async -> (any Error)? {
        do {
            let session = try await cloud(configuration)
            guard let member = try await session.membership(id) else { return nil }
            if member.pending != nil {
                guard sharingGraphs.insert(id).inserted else { throw GraphCloudError.busy }
                defer { sharingGraphs.remove(id) }
                do { try await session.executeSharing(member) }
                catch {
                    if var current = try await session.membership(id), current.generation == member.generation {
                        current.failure = Self.sharingDiagnostic(error)
                        if error as? GraphCloudSharingError == .superseded { current.pending = nil }
                        try await session.updateMembership(current)
                    }
                    throw error
                }
            }
            if member.terminal {
                if member.phase != .removed {
                    guard let location = locations[id] else { throw GraphCloudSharingError.metadataPending }
                    try await registerCloudGraphLocation(id, at: location.url, configuration: configuration)
                }
            } else if member.role == .participant { try await refreshCloudMembership(id, configuration: configuration) }
            return nil
        } catch { return error }
    }
}
