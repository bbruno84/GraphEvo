import Foundation

/// A resource-wide restriction retained independently of any application handle.
package actor StoreReservation {
    let id: UUID
    private let releaseBody: @Sendable () async -> Void
    private var releaseTask: Task<Void, Never>?

    package init(id: UUID, release: @escaping @Sendable () async -> Void) {
        self.id = id; releaseBody = release
    }
    package func release() async {
        if let releaseTask { return await releaseTask.value }
        let body = releaseBody
        let task = Task { await body() }; releaseTask = task
        await task.value
    }
    deinit {
        if releaseTask == nil { let body = releaseBody; Task { await body() } }
    }
}

enum StoreReservationMode: Sendable { case writes, all }
