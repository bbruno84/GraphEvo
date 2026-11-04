import Foundation
import os

/// Explicit account-bound cloud transport configuration. It does not select server entitlements.
public struct GraphCloudConnectionConfiguration: Sendable, Equatable {
    public let containerIdentifier: String
    public let environment: GraphCloudEnvironment
    public let directory: URL
    public let maximumEvents: Int
    public let maximumBytes: Int

    /// Creates a configuration without creating directories or starting account verification.
    public init(containerIdentifier: String, environment: GraphCloudEnvironment, directory: URL,
                maximumEvents: Int = 4096, maximumBytes: Int = 32 * 1024 * 1024) throws {
        guard !containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              directory.isFileURL, directory.query == nil, directory.fragment == nil,
              directory.path.hasPrefix("/"), maximumEvents > 0, maximumBytes > 0 else {
            throw GraphCloudConnectionError.invalidConfiguration
        }
        self.containerIdentifier = containerIdentifier; self.environment = environment
        self.directory = URL(fileURLWithPath: directory.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        self.maximumEvents = maximumEvents; self.maximumBytes = maximumBytes
    }
    var native: GraphCloudConfiguration {
        .init(containerIdentifier: containerIdentifier, environment: environment, directory: directory,
              maximumEvents: maximumEvents, maximumBytes: maximumBytes)
    }
}

/// A bounded failure category suitable for observable application state.
public struct GraphCloudConnectionFailure: Sendable, Equatable {
    public enum Category: Sendable, Equatable { case configuration, ownership, persistence, transport, recoveryRequired }
    public let category: Category
    /// Creates a payload-free category, including for application presentation tests.
    public init(category: Category) { self.category = category }
    init(_ error: any Error) {
        switch error {
        case GraphCloudError.invalidConfiguration, GraphCloudConnectionError.invalidConfiguration, GraphCloudNodeError.limitExceeded, GraphCloudActivationError.limitExceeded: category = .configuration
        case GraphCloudError.ownershipConflict, GraphCloudConnectionError.ownershipConflict, GraphStoreError.ownershipConflict, GraphStoreError.foreignGraph: category = .ownership
        case GraphCloudError.persistence: category = .persistence
        case GraphCloudError.invalidState, GraphCloudActivationError.recoveryRequired, GraphCloudActivationError.authorityConflict, GraphCloudActivationError.zoneNotEmpty, GraphCloudActivationError.invalidState: category = .recoveryRequired
        default: category = .transport
        }
    }
}

/// Account/session readiness, never proof that a graph or peer has finished synchronization.
public enum GraphCloudConnectionState: Sendable, Equatable {
    case verifyingAccount, ready, temporarilyUnavailable
    case isolated(GraphCloudAccountState.IsolationReason)
    case failed(GraphCloudConnectionFailure)
}

/// Connection operations preserve their underlying failure without putting SDK diagnostics in state.
public enum GraphCloudConnectionError: Error {
    case closed, notReady, invalidConfiguration, ownershipConflict, unavailableInExtension
    case operationFailed(GraphCloudConnectionFailure, underlying: any Error)
    static func translate(_ error: any Error) -> any Error {
        if error is CancellationError || error is GraphCloudConnectionError { return error }
        if case GraphCloudError.ownershipConflict = error { return Self.ownershipConflict }
        if case GraphCloudError.invalidConfiguration = error { return Self.invalidConfiguration }
        return Self.operationFailed(GraphCloudConnectionFailure(error), underlying: error)
    }
}

/// Locked state only; notifications never execute application code under the lock.
final class GraphCloudConnectionHub: Sendable {
    private struct State: Sendable {
        var current: GraphCloudConnectionState = .verifyingAccount
        var subscribers: [UUID: (owner: UUID, continuation: AsyncStream<Void>.Continuation)] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var current: GraphCloudConnectionState { state.withLock { $0.current } }
    func publish(_ value: GraphCloudConnectionState) {
        let targets = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            guard state.current != value else { return [] }
            state.current = value
            return state.subscribers.values.map(\.continuation)
        }
        for target in targets { target.yield(()) }
    }
    func observe(owner: UUID) -> GraphObservation<GraphCloudConnectionState> {
        let id = UUID(), ticks = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ticks.continuation.yield(())
        state.withLock { $0.subscribers[id] = (owner, ticks.continuation) }
        let pair = AsyncStream<GraphCloudConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let control = GraphObservationControl()
        pair.continuation.onTermination = { [weak control] _ in control?.cancel() }
        let remove: @Sendable () -> Void = { [weak self] in
            self?.state.withLock { $0.subscribers.removeValue(forKey: id)?.continuation }?.finish()
        }
        let worker = Task { [self] in
            defer { remove(); pair.continuation.finish() }
            for await _ in ticks.stream {
                guard !Task.isCancelled else { break }
                pair.continuation.yield(current)
            }
        }
        control.install(worker, refresh: { ticks.continuation.yield(()) }, finish: { remove(); pair.continuation.finish() })
        return GraphObservation(stream: pair.stream, control: control)
    }
    func finish(owner: UUID) {
        let targets = state.withLock { state in
            let values = state.subscribers.filter { $0.value.owner == owner }
            for id in values.keys { state.subscribers.removeValue(forKey: id) }
            return values.values.map(\.continuation)
        }
        for target in targets { target.finish() }
    }
}

extension GraphContextManager {
    func publishCloudConnectionState(_ namespace: String, failure: (any Error)? = nil) async {
        guard let hub = publicConnectionHubs[namespace] else { return }
        let generation = cloudSessions[namespace]?.id, revision = accountRevision
        let sessionStatus = await cloudSessions[namespace]?.session?.status()
        guard generation == cloudSessions[namespace]?.id, revision == accountRevision else {
            await publishCloudConnectionState(namespace)
            return
        }
        guard let authority = accountAuthorities[namespace] else { hub.publish(.verifyingAccount); return }
        if let reason = authority.isolation {
            if case .isolated(let publicReason) = GraphCloudAccountState(.isolated(reason)) { hub.publish(.isolated(publicReason)) }
            return
        }
        if authority.temporary { hub.publish(.temporarilyUnavailable); return }
        if let failure {
            if case GraphCloudError.accountChanged = failure, sessionStatus != nil,
               sessionStatus?.failure == nil, authority.verifiedAccount != nil {
                hub.publish(.ready)
            } else { hub.publish(.failed(.init(failure))) }
            return
        }
        if let error = sessionStatus?.failure { hub.publish(.failed(.init(error))); return }
        hub.publish(authority.verifiedAccount != nil && sessionStatus != nil ? .ready : .verifyingAccount)
    }
}

