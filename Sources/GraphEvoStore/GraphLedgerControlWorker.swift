import Foundation
import GraphEvoModel

extension GraphContextManager {
    func setLedgerControlActive(_ active: Bool, revision: UInt64, configuration: GraphCloudConfiguration,
                               clock: GraphAutomaticClock) async {
        guard let sessionID = ledgerSessionGeneration(configuration),
              revision >= (ledgerActivity[configuration.namespace]?.revision ?? 0) else { return }
        ledgerActivity[configuration.namespace] = (sessionID, active, revision, clock)
        let enabled = (try? await ledgerCloud(configuration, generation: sessionID).enabledLedgerIDs()) ?? []
        guard ledgerSessionGeneration(configuration) == sessionID, ledgerActivity[configuration.namespace]?.revision == revision else { return }
        for scope in [GraphCloudScope.private, .shared] {
            guard ledgerSessionGeneration(configuration) == sessionID, ledgerActivity[configuration.namespace]?.revision == revision else { return }
            let key = configuration.namespace + ":" + scope.rawValue
            if ledgerWorkers[key] == nil, !enabled.isEmpty {
                ledgerWorkers[key] = GraphSharingLifecycleWorker(clock: clock, retryPermission: true, generation: { [weak self] id in
                    guard let self else { return nil }
                    return try? await self.ledgerCloud(configuration, generation: sessionID).ledgerGeneration(id)
                }, inventory: { [weak self] in
                    guard let self else { return [] }
                    return (try? await self.ledgerCloud(configuration, generation: sessionID).enabledLedgerIDs(in: scope)) ?? []
                }, step: { [weak self] id in
                    guard let self else { return GraphCloudError.stopped }
                    do {
                        let session = try await self.ledgerCloud(configuration, generation: sessionID)
                        let generation = try await session.ensureLedger(id, writing: false).generation
                        do {
                            if let member = try await session.membership(id), member.role == .participant, !member.terminal {
                                try await self.refreshCloudMembership(id, configuration: configuration)
                            }
                            _ = try await session.synchronizeLedger(id)
                            return nil
                        } catch {
                            try? await session.recordLedgerFailure(id, generation: generation, error: error)
                            return error
                        }
                    } catch { return error }
                })
            }
            await ledgerWorkers[key]?.setActive(active, revision: revision)
        }
        if ledgerListeners[configuration.namespace] == nil, let feed = try? await ledgerCloud(configuration, generation: sessionID).ledgerSignalFeed() {
            guard ledgerSessionGeneration(configuration) == sessionID, ledgerActivity[configuration.namespace] != nil,
                  ledgerListeners[configuration.namespace] == nil else { feed.cancel(); return }
            ledgerListeners[configuration.namespace] = Task { [weak self] in
                defer { feed.cancel() }
                for await _ in feed.stream {
                    if Task.isCancelled { break }
                    await self?.ledgerControlSignalled(configuration, generation: sessionID)
                }
            }
        }
    }
    func ledgerControlSignalled(_ configuration: GraphCloudConfiguration, scope: GraphCloudScope? = nil, explicit: Bool = false, generation: UUID? = nil) async {
        if let generation { guard ledgerSessionGeneration(configuration) == generation else { return } }
        let ids = (try? await cloud(configuration).enabledLedgerIDs(in: scope)) ?? []
        await requestLedgerControl(configuration, ids: ids, explicit: explicit)
    }
    func requestLedgerControl(_ configuration: GraphCloudConfiguration, ids: [GraphID], explicit: Bool) async {
        if !ids.isEmpty, let activity = ledgerActivity[configuration.namespace],
           ledgerWorkers[configuration.namespace + ":private"] == nil {
            await setLedgerControlActive(activity.active, revision: activity.revision, configuration: configuration, clock: activity.clock)
        }
        for scope in [GraphCloudScope.private, .shared] {
            await ledgerWorkers[configuration.namespace + ":" + scope.rawValue]?.request(ids, explicit: explicit)
        }
    }
    func ledgerControlSuccess(_ id: GraphID, configuration: GraphCloudConfiguration) async {
        for scope in [GraphCloudScope.private, .shared] {
            await ledgerWorkers[configuration.namespace + ":" + scope.rawValue]?.recordSuccess(id)
        }
    }
    func stopLedgerControl(_ configuration: GraphCloudConfiguration) async {
        ledgerActivity.removeValue(forKey: configuration.namespace)
        ledgerListeners.removeValue(forKey: configuration.namespace)?.cancel()
        for scope in [GraphCloudScope.private, .shared] {
            if let worker = ledgerWorkers.removeValue(forKey: configuration.namespace + ":" + scope.rawValue) { await worker.shutdown() }
        }
    }
}
