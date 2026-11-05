import Foundation
import GraphEvoModel
import GraphEvoRuntime

struct GraphAccountAuthority {
    let id = UUID()
    let container: String
    let environment: GraphCloudEnvironment
    var configuration: GraphCloudConfiguration?
    var adapter: GraphCloudAdapter
    var disk: GraphCloudDisk
    var observation: GraphCloudAccountObservation?
    var query = UUID()
    var verification: Task<GraphCloudAccountAvailability, any Error>?
    var observedAccount: String?
    var verifiedAccount: String?
    var isolation: StoreAccountIsolation?
    var temporary = false
    var wantsCloud = true
    var requiresEngineReset = false
    init(configuration: GraphCloudConfiguration, adapter: GraphCloudAdapter, disk: GraphCloudDisk) {
        container = configuration.containerIdentifier; environment = configuration.environment
        self.configuration = configuration; self.adapter = adapter; self.disk = disk
    }
    init(identity: GraphCloudSessionIdentity, adapter: GraphCloudAdapter) {
        container = identity.container; environment = identity.environment
        configuration = nil; self.adapter = adapter; disk = .live; wantsCloud = false
    }
}
struct GraphAccountVerification {
    let authority: UUID
    let query: UUID
    let account: String
}

extension GraphContextManager {
    /// Recheck after foregrounding, notifications or a consumer-requested retry. No data is relabeled.
    package func refreshCloudAccount(_ configuration: GraphCloudConfiguration) async throws {
        guard let authority = accountAuthorities[configuration.namespace], authority.configuration == configuration else {
            throw GraphCloudError.stopped
        }
        try await refreshAccount(configuration.namespace)
    }

    func refreshAccount(_ key: String) async throws {
        guard let authority = accountAuthorities[key] else { return }
        accountAuthorities[key]!.query = UUID()
        accountAuthorities[key]!.verification = nil
        if authority.wantsCloud, !publicBackgroundSessions.contains(key), let configuration = authority.configuration {
            _ = try await startCloudSession(configuration, adapter: authority.adapter, disk: authority.disk)
        } else {
            let verification = try await verifyAccount(key)
            try await finishAccountVerification(verification, namespace: key)
        }
    }

    func scheduleAccountRefresh(_ namespace: String) {
        if accountRefreshTasks[namespace] != nil {
            // A notification during a query must invalidate its result and trigger a fresh query.
            accountAuthorities[namespace]?.query = UUID()
            accountAuthorities[namespace]?.verification = nil
            accountRefreshPending.insert(namespace)
            return
        }
        accountRefreshTasks[namespace] = Task { [weak self] in
            guard let self else { return }
            await self.runAccountRefresh(namespace)
        }
    }
    private func runAccountRefresh(_ namespace: String) async {
        defer { accountRefreshTasks.removeValue(forKey: namespace) }
        guard accountAuthorities[namespace] != nil else { return }
        var retriedStaleStartup = false
        repeat {
            accountRefreshPending.remove(namespace)
            do { try await refreshAccount(namespace) }
            catch GraphCloudError.accountChanged {
                // An explicit startup may still own the invalidated preflight. Drain its
                // waiters before one fresh account query; never retry a confirmed switch.
                if !retriedStaleStartup, accountAuthorities[namespace]?.isolation == nil {
                    retriedStaleStartup = true
                    if let opening = accountOpenings[namespace] {
                        await withCheckedContinuation { accountOpeningDrains[opening.id, default: []].append($0) }
                    }
                    accountRefreshPending.insert(namespace)
                }
            } catch { /* State carries availability and verification failures. */ }
        } while accountRefreshPending.contains(namespace)
    }

    func verifyAccountForStart(_ configuration: GraphCloudConfiguration, adapter: GraphCloudAdapter,
                               disk: GraphCloudDisk, wantsCloud: Bool = true) async throws -> GraphAccountVerification {
        let key = configuration.namespace
        if accountAuthorities[key] == nil {
            accountAuthorities[key] = GraphAccountAuthority(configuration: configuration, adapter: adapter, disk: disk)
        }
        accountAuthorities[key]!.configuration = configuration
        accountAuthorities[key]!.adapter = adapter
        accountAuthorities[key]!.disk = disk
        if !accountAuthorities[key]!.wantsCloud {
            accountAuthorities[key]!.query = UUID(); accountAuthorities[key]!.verification = nil
        }
        accountAuthorities[key]!.wantsCloud = wantsCloud
        return try await verifyAccount(key)
    }

    func verifyAccount(_ key: String) async throws -> GraphAccountVerification {
        guard let authorityValue = accountAuthorities[key] else { throw GraphCloudError.stopped }
        let adapter = authorityValue.adapter
        if accountAuthorities[key]!.observation == nil, let observe = adapter.observeAccount {
            accountAuthorities[key]!.observation = observe { [weak self] in
                Task { await self?.scheduleAccountRefresh(key) }
            }
        }
        if accountAuthorities[key]!.verification == nil {
            let identifier = authorityValue.container
            accountAuthorities[key]!.verification = Task.detached { try await adapter.readAccountAvailability(identifier) }
        }
        let query = accountAuthorities[key]!.query, authority = accountAuthorities[key]!.id
        defer {
            if accountAuthorities[key]?.id == authority, accountAuthorities[key]?.query == query {
                accountAuthorities[key]!.verification = nil
            }
        }
        let availability: GraphCloudAccountAvailability
        do { availability = try await accountAuthorities[key]!.verification!.value }
        catch {
            if accountAuthorities[key]?.query == query { await recordAccountIsolation(.verificationRequired, namespace: key) }
            throw error
        }
        guard accountAuthorities[key]?.id == authority, accountAuthorities[key]?.query == query else { throw GraphCloudError.accountChanged }
        switch availability {
        case .available(let account):
            guard !account.isEmpty else { throw GraphCloudError.accountUnavailable }
            if accountClaims.values.contains(where: { $0.container == authorityValue.container && $0.environment == authorityValue.environment && $0.account != account }) ||
                (authorityValue.observedAccount != nil && authorityValue.observedAccount != account) {
                accountAuthorities[key]!.requiresEngineReset = true
            }
            accountAuthorities[key]!.observedAccount = account
            // A newly observed different identity must close old handles before any attempted startup.
            accountRevision += 1
            for (id, identity) in accountClaims where identity.container == authorityValue.container && identity.environment == authorityValue.environment && identity.account != account {
                accountControls[id]?.update(.isolated(.differentAccount), revision: accountRevision)
            }
            if let session = cloudSessions[key]?.session, await session.retainedIdentity().account != account {
                await session.receive(.account(account), scope: .private)
                throw GraphCloudError.accountChanged
            }
            return .init(authority: authority, query: query, account: account)
        case .temporarilyUnavailable:
            accountAuthorities[key]!.temporary = true
            accountRevision += 1
            await applyAccountAuthority(key)
            if let session = cloudSessions[key]?.session { await session.suspendForUnavailableAccount() }
        case .signedOut:
            await recordAccountIsolation(.signedOut, namespace: key)
            if let session = cloudSessions[key]?.session { await session.receive(.account(nil), scope: .private) }
        case .restricted:
            await recordAccountIsolation(.restricted, namespace: key)
            if let session = cloudSessions[key]?.session { await session.suspendForUnavailableAccount() }
        }
        throw GraphCloudError.accountUnavailable
    }

    func finishAccountVerification(_ verification: GraphAccountVerification, configuration: GraphCloudConfiguration) async throws {
        try await finishAccountVerification(verification, namespace: configuration.namespace)
    }
    func finishAccountVerification(_ verification: GraphAccountVerification, namespace key: String) async throws {
        guard accountAuthorities[key]?.id == verification.authority,
              accountAuthorities[key]?.query == verification.query else { throw GraphCloudError.accountChanged }
        accountAuthorities[key]!.verifiedAccount = verification.account
        accountAuthorities[key]!.observedAccount = verification.account
        accountAuthorities[key]!.isolation = nil
        accountAuthorities[key]!.temporary = false
        accountRevision += 1
        await applyAccountAuthority(key)
    }

    func accountState(for identity: GraphCloudSessionIdentity) -> StoreAccountStatus {
        let key = identity.environment.rawValue + ":" + identity.container
        guard let authority = accountAuthorities[key] else { return .isolated(.verificationRequired) }
        if let observed = authority.observedAccount, observed != identity.account { return .isolated(.differentAccount) }
        if let isolation = authority.isolation { return .isolated(isolation) }
        guard let verified = authority.verifiedAccount else { return .isolated(.verificationRequired) }
        guard verified == identity.account else { return .isolated(.differentAccount) }
        return authority.temporary ? .temporarilyUnavailable : .available
    }
    func applyAccountToOwner(_ owner: GraphCoordinator, identity: GraphCloudSessionIdentity) async throws {
        let control = try await owner.accountControl()
        control.update(accountState(for: identity), revision: accountRevision)
    }
    func applyAccountAuthority(_ namespace: String) async {
        for (id, identity) in accountClaims where identity.environment.rawValue + ":" + identity.container == namespace {
            accountControls[id]?.update(accountState(for: identity), revision: accountRevision)
        }
        await publishCloudConnectionState(namespace)
    }
    private func recordAccountIsolation(_ reason: StoreAccountIsolation, namespace: String) async {
        guard accountAuthorities[namespace] != nil else { return }
        accountAuthorities[namespace]!.query = UUID()
        accountAuthorities[namespace]!.verification = nil
        accountAuthorities[namespace]!.isolation = reason
        if reason != .verificationRequired { accountAuthorities[namespace]!.requiresEngineReset = true }
        accountAuthorities[namespace]!.temporary = false
        accountRevision += 1
        await applyAccountAuthority(namespace)
    }

    func sessionAccountSignal(_ signal: GraphCloudSessionAccountSignal, namespace: String, generation: UUID) async {
        guard cloudSessions[namespace]?.id == generation else { return }
        switch signal {
        case .signedOut: await recordAccountIsolation(.signedOut, namespace: namespace)
        case .differentAccount: await recordAccountIsolation(.differentAccount, namespace: namespace)
        case .restricted: await recordAccountIsolation(.restricted, namespace: namespace)
        case .signedIn: scheduleAccountRefresh(namespace)
        case .temporarilyUnavailable:
            accountAuthorities[namespace]?.temporary = true
            accountRevision += 1
            await applyAccountAuthority(namespace)
        }
    }

    func claimCloudAccount(_ identity: GraphCloudSessionIdentity, for id: GraphID, owner: GraphCoordinator) async throws {
        if let old = accountClaims[id], old != identity { throw GraphCloudError.ownershipConflict }
        if let existing = try await owner.accountIdentity(), existing != identity { throw GraphCloudError.ownershipConflict }
        accountControls[id] = try await owner.accountControl()
        accountClaims[id] = identity
        try await owner.claimAccount(identity)
        try await applyAccountToOwner(owner, identity: identity)
        guard accountState(for: identity).allowsData else { throw GraphCloudError.accountChanged }
    }
    func restoreAccountOnOpen(_ id: GraphID, owner: GraphCoordinator) async throws -> Bool {
        if let identity = try await owner.accountIdentity() {
            if let old = accountClaims[id], old != identity { throw GraphCloudError.ownershipConflict }
            accountControls[id] = try await owner.accountControl()
            accountClaims[id] = identity
            try await applyAccountToOwner(owner, identity: identity)
            if let localAccountAdapter {
                let namespace = identity.environment.rawValue + ":" + identity.container
                if accountAuthorities[namespace] == nil {
                    accountAuthorities[namespace] = GraphAccountAuthority(identity: identity, adapter: localAccountAdapter)
                    scheduleAccountRefresh(namespace)
                }
            }
            return accountState(for: identity).allowsData
        }
        guard accountClaims[id] == nil else { throw GraphCloudError.invalidState }
        return true
    }
}
