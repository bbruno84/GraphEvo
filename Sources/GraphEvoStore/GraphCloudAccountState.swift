import CoreData
import Foundation
import GraphEvoRuntime
import GraphEvoModel

/// Identity/access state of this local graph, not a synchronization completion signal.
public enum GraphCloudAccountState: Sendable, Equatable {
    public enum IsolationReason: Sendable, Equatable { case verificationRequired, signedOut, differentAccount, restricted }
    case localOnly, available, temporarilyUnavailable
    case isolated(IsolationReason)

    init(_ state: StoreAccountStatus) {
        switch state {
        case .localOnly: self = .localOnly
        case .available: self = .available
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .isolated(let reason):
            switch reason {
            case .verificationRequired: self = .isolated(.verificationRequired)
            case .signedOut: self = .isolated(.signedOut)
            case .differentAccount: self = .isolated(.differentAccount)
            case .restricted: self = .isolated(.restricted)
            }
        }
    }
}

package struct GraphCloudAccountNativeAdapter: Sendable {
    package let read: @Sendable (NSManagedObjectContext, GraphID) throws -> GraphCloudSessionIdentity?
    package let claim: @Sendable (NSManagedObjectContext, GraphID, GraphCloudSessionIdentity) throws -> Void
    package init(read: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> GraphCloudSessionIdentity?,
                 claim: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudSessionIdentity) throws -> Void) {
        self.read = read; self.claim = claim
    }
}

extension GraphStore {
    /// Available while isolated so the consumer can replace cached UI and explain the restriction.
    public var cloudAccountState: GraphCloudAccountState {
        get async throws {
            do { return GraphCloudAccountState(try await handle.accountStatus()) }
            catch { throw Self.translate(error) }
        }
    }

    /// Newest current state, including an initial value; account identities are never exposed.
    public func observeCloudAccountState() async throws -> GraphObservation<GraphCloudAccountState> {
        let feed: StoreAccountFeed
        do { feed = try await handle.accountFeed() } catch { throw Self.translate(error) }
        let pair = AsyncStream<GraphCloudAccountState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let control = GraphObservationControl()
        pair.continuation.onTermination = { [weak control] _ in control?.cancel() }
        let worker = Task {
            defer { feed.cancel(); pair.continuation.finish() }
            for await _ in feed.stream {
                guard !Task.isCancelled else { break }
                pair.continuation.yield(GraphCloudAccountState(feed.current()))
            }
        }
        control.install(worker, refresh: feed.refresh, finish: { feed.cancel(); pair.continuation.finish() })
        return GraphObservation(stream: pair.stream, control: control)
    }

    package func accountCheck() async throws -> @Sendable () throws -> Void {
        let permit: StoreAccountPermit
        do { permit = try await handle.accountPermit() } catch { throw Self.translate(error) }
        return {
            do { try permit.check() } catch { throw Self.translate(error) }
        }
    }
}
