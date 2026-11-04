import Foundation
import GraphEvoModel
import GraphEvoRuntime

struct GraphAccountAuthority {
    let id = UUID()
    var configuration: GraphCloudConfiguration
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
        accountAuthorities[configuration.namespace]!.query = UUID()
        accountAuthorities[configuration.namespace]!.verification = nil
        if authority.wantsCloud {
            _ = try await startCloudSession(configuration, adapter: authority.adapter, disk: authority.disk)
        } else {
            let verification = try await verifyAccountForStart(configuration, adapter: authority.adapter,
                                                               disk: authority.disk, wantsCloud: false)
            try await finishAccountVerification(verification, configuration: configuration)
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
        guard let configuration = accountAuthorities[namespace]?.configuration else { return }
        repeat {
            accountRefreshPending.remove(namespace)
            // Availability/access state is published even if CloudKit startup cannot complete.
            try? await refreshCloudAccount(configuration)
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
        if accountAuthorities[key]!.observation == nil, let observe = adapter.observeAccount {
            accountAuthorities[key]!.observation = observe { [weak self] in
                Task { await self?.scheduleAccountRefresh(key) }
            }
        }
        if accountAuthorities[key]!.verification == nil {
            let identifier = configuration.containerIdentifier
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
            accountAuthorities[key]!.observedAccount = account
            // A newly observed different identity must close old handles before any attempted startup.
            accountRevision += 1
            for (id, identity) in accountClaims where identity.container == configuration.containerIdentifier && identity.environment == configuration.environment && identity.account != account {
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
        let key = configuration.namespace
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
    private func applyAccountAuthority(_ namespace: String) async {
        for (id, identity) in accountClaims where identity.environment.rawValue + ":" + identity.container == namespace {
            accountControls[id]?.update(accountState(for: identity), revision: accountRevision)
        }
    }
    private func recordAccountIsolation(_ reason: StoreAccountIsolation, namespace: String) async {
        guard accountAuthorities[namespace] != nil else { return }
        accountAuthorities[namespace]!.query = UUID()
        accountAuthorities[namespace]!.verification = nil
        accountAuthorities[namespace]!.isolation = reason
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
            return accountState(for: identity).allowsData
        }
        guard accountClaims[id] == nil else { throw GraphCloudError.invalidState }
        return true
    }
}
