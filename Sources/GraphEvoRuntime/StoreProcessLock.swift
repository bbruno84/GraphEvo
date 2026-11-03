import CryptoKit
import Darwin
import Foundation
import os

/// Advisory exclusion for coordinated local stores. Every participating writer must use this gateway.
/// Stable sidecars belong to the location and must survive replacement, close and process death.
enum StoreProcessLock {
    @TaskLocal static var held: Set<StoreKey> = []
    private static let io = DispatchQueue(label: "GraphEvo.store-lock.io")

    enum Mode: Sendable { case shared, exclusive }

    /// The descriptor has single-close ownership. No thread mutex is held across an await.
    final class Lease: Sendable {
        private final class Descriptor: Sendable {
            let value: Int32
            init(_ value: Int32) { self.value = value }
            deinit { _ = flock(value, LOCK_UN); _ = Darwin.close(value) }
        }
        private let descriptor: OSAllocatedUnfairLock<Descriptor?>
        init(_ value: Int32) { descriptor = OSAllocatedUnfairLock(initialState: Descriptor(value)) }
        private init(_ value: Descriptor) { descriptor = OSAllocatedUnfairLock(initialState: value) }
        /// An admitted maintenance operation retains its fence even if the reservation is released.
        func retained() -> Lease? { descriptor.withLock { $0.map(Lease.init) } }
        func release() {
            let previous = descriptor.withLock { value in let old = value; value = nil; return old }
            withExtendedLifetime(previous) {}
        }
        deinit { release() }
    }

    static func sidecar(_ resolved: ResolvedStore, purpose: String) throws -> URL {
        guard case .sqlite(let key) = resolved.key, let url = resolved.url else {
            throw StoreRuntimeError.invalidConfiguration("A process lock requires a local SQLite resource.")
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return url.deletingLastPathComponent().appendingPathComponent(".graphevo-" + digest + "." + purpose + ".lock")
    }

    private static func verify(_ fd: Int32, path: String) throws {
        var handle = stat(), entry = stat()
        guard fstat(fd, &handle) == 0, lstat(path, &entry) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard handle.st_dev == entry.st_dev, handle.st_ino == entry.st_ino,
              handle.st_nlink == 1, (handle.st_mode & S_IFMT) == S_IFREG,
              handle.st_uid == geteuid(), (handle.st_mode & 0o077) == 0 else {
            throw StoreRuntimeError.invalidConfiguration("The store lock sidecar has an unsafe identity or permissions.")
        }
    }

    /// Nonblocking system calls run on a dedicated queue; contention suspends the caller.
    /// Maintenance uses wait=false so another idle coordinator cannot be destroyed underneath its leases.
    static func acquire(_ resolved: ResolvedStore, purpose: String = "writer", mode: Mode = .exclusive,
                        wait: Bool = true, cancellable: Bool = true,
                        contended: (@Sendable () -> Void)? = nil) async throws -> Lease {
        if cancellable { try Task.checkCancellation() }
        let path = try sidecar(resolved, purpose: purpose).path
        let fd: Int32 = try await withCheckedThrowingContinuation { continuation in
            io.async {
                do {
                    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                            withIntermediateDirectories: true)
                    let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    do { try verify(fd, path: path); continuation.resume(returning: fd) }
                    catch { _ = Darwin.close(fd); throw error }
                } catch { continuation.resume(throwing: error) }
            }
        }
        var transferred = false
        defer { if !transferred { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) } }
        while true {
            if cancellable { try Task.checkCancellation() }
            let acquired: Bool = try await withCheckedThrowingContinuation { continuation in
                io.async {
                    do {
                        try verify(fd, path: path)
                        if flock(fd, (mode == .exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 {
                            try verify(fd, path: path)
                            continuation.resume(returning: true)
                        } else if errno == EWOULDBLOCK || errno == EAGAIN {
                            continuation.resume(returning: false)
                        } else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    } catch { continuation.resume(throwing: error) }
                }
            }
            if acquired {
                if cancellable { try Task.checkCancellation() }
                transferred = true
                return Lease(fd)
            }
            contended?()
            guard wait else { throw StoreRuntimeError.resourceReserved }
            if cancellable { try await Task.sleep(for: .milliseconds(25)) }
            else {
                // Cleanup is not abandoned when its initiating caller is cancelled.
                await withCheckedContinuation { continuation in
                    io.asyncAfter(deadline: .now() + .milliseconds(25)) { continuation.resume() }
                }
            }
        }
    }
}
