import Foundation

/// Callers share refresh work, but own independent cancellation and wait deadlines.
actor GraphCloudAttachmentRefresh<Value: Sendable> {
    private struct Job {
        let generation: UUID
        var waiters: [UUID: CheckedContinuation<Value, any Error>]
    }
    private var jobs: [String: Job] = [:]
    var registeredWaiterCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }

    func run(_ key: String, work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let token = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if var job = jobs[key] {
                    job.waiters[token] = continuation
                    jobs[key] = job
                } else {
                    let generation = UUID()
                    jobs[key] = Job(generation: generation, waiters: [token: continuation])
                    Task {
                        let result: Result<Value, any Error>
                        do { result = .success(try await work()) } catch { result = .failure(error) }
                        finish(key, generation: generation, result: result)
                    }
                }
            }
        } onCancel: { Task { await self.cancel(key, token: token) } }
    }

    private func cancel(_ key: String, token: UUID) {
        jobs[key]?.waiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }
    private func finish(_ key: String, generation: UUID, result: Result<Value, any Error>) {
        guard let job = jobs[key], job.generation == generation else { return }
        jobs.removeValue(forKey: key)
        for continuation in job.waiters.values { continuation.resume(with: result) }
    }
}
