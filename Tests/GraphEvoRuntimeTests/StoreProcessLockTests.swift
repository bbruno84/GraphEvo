import CoreData
import Darwin
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreProcessLockTests {
    private func resource() throws -> ResolvedStore {
        let root = try temporaryDirectory()
        return try ResolvedStore(.init(location: .sqlite(root.appendingPathComponent("Main.sqlite")), exclusiveGraphID: UUID()))
    }

    @Test func cancellationAfterRealContentionNeverRunsTheBodyAndReleasesTheDescriptor() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try await StoreProcessLock.acquire(resolved)
        let events = AsyncStream<Void>.makeStream()
        let waiting = Task {
            let lock = try await StoreProcessLock.acquire(resolved, contended: { events.continuation.yield(()) })
            defer { lock.release() }
            Issue.record("A cancelled contended request acquired the store.")
        }
        var observer = events.stream.makeAsyncIterator()
        _ = await observer.next()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        held.release()
        let following = try await StoreProcessLock.acquire(resolved, wait: false)
        following.release()
        events.continuation.finish()
    }

    @Test func canonicalAliasUsesTheSameStableLockAndAnIndependentStoreDoesNotWait() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let alternate = try ResolvedStore(.init(location: .sqlite(alias.appendingPathComponent("Main.sqlite"))))
        #expect(try StoreProcessLock.sidecar(resolved, purpose: "writer") == StoreProcessLock.sidecar(alternate, purpose: "writer"))
        let first = try await StoreProcessLock.acquire(resolved)
        await #expect(throws: StoreRuntimeError.self) { try await StoreProcessLock.acquire(alternate, wait: false) }
        let other = try ResolvedStore(.init(location: .sqlite(root.appendingPathComponent("Other.sqlite"))))
        let independent = try await StoreProcessLock.acquire(other, wait: false)
        independent.release(); first.release()
        #expect(FileManager.default.fileExists(atPath: try StoreProcessLock.sidecar(resolved, purpose: "writer").path))
    }

    @Test func sidecarSymlinkIsRefusedWithoutFollowingOrRemovingIt() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated")
        try Data([1, 2, 3]).write(to: target)
        let sidecar = try StoreProcessLock.sidecar(resolved, purpose: "writer")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await StoreProcessLock.acquire(resolved) }
        #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path) == target.path)
    }

    @Test func aWaiterCannotAdoptARecreatedSidecarAfterWorkspaceRetirement() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try await StoreProcessLock.acquire(resolved)
        let events = AsyncStream<Void>.makeStream()
        let waiting = Task {
            try await StoreProcessLock.acquire(resolved, contended: { events.continuation.yield(()) })
        }
        var observer = events.stream.makeAsyncIterator()
        _ = await observer.next()
        // Disposable fault injection: the old waiter already owns a descriptor for this inode.
        try FileManager.default.removeItem(at: StoreProcessLock.sidecar(resolved, purpose: "writer"))
        let replacement = try await StoreProcessLock.acquire(resolved, wait: false)
        await #expect(throws: StoreRuntimeError.self) { try await waiting.value }
        replacement.release(); held.release()
        events.continuation.finish()
    }

    @Test func liveOwnersPermitWritersButRefuseDestructiveMaintenance() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared)
        let second = try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared)
        let writer = try await StoreProcessLock.acquire(resolved, wait: false)
        writer.release()
        first.release()
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreProcessLock.acquire(resolved, purpose: "owners", wait: false)
        }
        second.release()
        let maintenance = try await StoreProcessLock.acquire(resolved, purpose: "owners", wait: false)
        maintenance.release()
    }

    @Test func anAdmittedBorrowKeepsTheLockAfterItsReservationReleases() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let reservation = try await StoreProcessLock.acquire(resolved)
        let operation = try #require(reservation.retained())
        reservation.release()
        #expect(reservation.retained() == nil)
        await #expect(throws: StoreRuntimeError.self) { try await StoreProcessLock.acquire(resolved, wait: false) }
        operation.release()
        let next = try await StoreProcessLock.acquire(resolved, wait: false)
        next.release()
    }

    @Test func maintenanceReservationRetainsTheProcessFenceUntilRelease() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await StoreRegistry().open(resolved.configuration, schema: fixtureSchema())
        let reservation = try await handle.reserveMaintenance()
        await #expect(throws: StoreRuntimeError.self) { try await StoreProcessLock.acquire(resolved, wait: false) }
        try await handle.copyStore(to: root.appendingPathComponent("Backup.sqlite"), reservation: reservation)
        await reservation.release()
        let next = try await StoreProcessLock.acquire(resolved, wait: false)
        next.release()
        try await handle.close()
    }

    @Test func destructiveMaintenanceRefusesAnIdleOwnerAndCanRetryAfterItCloses() async throws {
        let resolved = try resource(), url = try #require(resolved.url), root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let graphID = try #require(resolved.configuration.exclusiveGraphID)
        let handle = try await StoreRegistry().open(resolved.configuration, schema: fixtureSchema())
        let storeID = try await handle.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let coordinator = try #require(context.persistentStoreCoordinator)
                let store = try #require(coordinator.persistentStores.first)
                var metadata = coordinator.metadata(for: store)
                metadata[StoreNativeContext.historySyncGraphKey] = graphID.uuidString
                coordinator.setMetadata(metadata, for: store)
                NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue("retained", forKey: "value")
                try context.save()
                return try #require(metadata[NSStoreUUIDKey] as? String)
            }
        }
        // A separately opened descriptor models another process's live, idle native owner.
        let idleOwner = try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared)
        await #expect(throws: StoreRuntimeError.self) { try await handle.destroy(graphID: graphID, storeID: storeID) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        idleOwner.release()
        try await handle.destroy(graphID: graphID, storeID: storeID)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await handle.close()
    }

    @Test func inheritedNativeReentryRefusesWritersAndReservationsWithoutPoisoningTheOwner() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await StoreRegistry().open(resolved.configuration, schema: fixtureSchema())
        try await handle.nativeOperation { _ in
            await #expect(throws: StoreRuntimeError.self) { try await handle.transaction { _ in () } }
            await #expect(throws: StoreRuntimeError.self) { try await handle.reserveMaintenance() }
        }
        try await handle.transaction { context in
            NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue("following", forKey: "value")
        }
        try await handle.close()
    }

    @Test func workspaceOwnershipIsExclusiveBeforeMigrationAndUntilFinalDetach() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source.sqlite")
        let source = try await StoreRegistry().open(.init(location: .sqlite(sourceURL)), schema: fixtureSchema())
        try await source.transaction { context in
            NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue("source", forKey: "value")
        }
        try await source.close()
        let targetURL = root.appendingPathComponent("Workspace.sqlite")
        let configuration = StoreConfiguration(location: .sqlite(targetURL), exclusiveGraphID: UUID(),
            workspaceID: UUID(), workspaceSessionID: UUID())
        let resolved = try ResolvedStore(configuration)
        let migration = StoreNativeMigration(sourceSchema: fixtureSchema(), seedURL: sourceURL, document: Data([1]),
            configure: { _, _ in }, finish: { _ in })
        let idleOwner = try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared)
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreRegistry().open(configuration, schema: fixtureSchema(), nativeMigration: migration)
        }
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        idleOwner.release()
        let target = try await StoreRegistry().open(configuration, schema: fixtureSchema(), nativeMigration: migration)
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared, wait: false)
        }
        #expect(try await target.read { try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "RuntimeFixture")) } == 1)
        try await target.close()
        let followingOwner = try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared, wait: false)
        // Resuming an already converted workspace also requires exclusive ownership.
        await #expect(throws: StoreRuntimeError.self) { try await StoreRegistry().open(configuration, schema: fixtureSchema()) }
        followingOwner.release()
        let resumed = try await StoreRegistry().open(configuration, schema: fixtureSchema())
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreProcessLock.acquire(resolved, purpose: "owners", mode: .shared, wait: false)
        }
        try await resumed.close()
    }

    @Test func unmarkedReadOnlyArchiveDoesNotRequireSourceSidecars() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source.sqlite")
        let source = try await StoreRegistry().open(.init(location: .sqlite(sourceURL)), schema: fixtureSchema())
        try await source.close()
        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let url = archive.appendingPathComponent("ReadOnly.sqlite")
        try FileManager.default.copyItem(at: sourceURL, to: url)
        let reader = try await StoreRegistry().open(.init(location: .sqlite(url), access: .readOnly), schema: fixtureSchema())
        try await reader.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).allSatisfy { !$0.hasPrefix(".graphevo-") })
    }

    @Test func bootstrapAndTransactionsUseTheSameLockBeforeNativeAccess() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try await StoreProcessLock.acquire(resolved)
        let events = AsyncStream<Void>.makeStream()
        let registry = StoreRegistry(hooks: .init(didContendProcessLock: { events.continuation.yield(()) }))
        let opening = Task { try await registry.open(resolved.configuration, schema: fixtureSchema()) }
        var observer = events.stream.makeAsyncIterator()
        _ = await observer.next()
        #expect(!FileManager.default.fileExists(atPath: try #require(resolved.url).path))
        held.release()
        let handle = try await opening.value
        let external = try await StoreProcessLock.acquire(resolved)
        let writing = Task {
            try await handle.transaction { context in
                #expect(context.userInfo[StoreNativeContext.mutationSessionKey] is StoreMutationSession)
                NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue("kept", forKey: "value")
            }
        }
        _ = await observer.next()
        external.release()
        try await writing.value
        #expect(try await handle.read { context in
            let count = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "RuntimeFixture"))
            return context.userInfo[StoreNativeContext.mutationSessionKey] == nil && count == 1
        })
        try await handle.close()
        events.continuation.finish()
    }

    #if os(macOS)
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func independentProcessDeathReleasesTheActualStoreLock() async throws {
        let resolved = try resource(), root = try #require(resolved.url).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-MFcntl=:flock,:DEFAULT", "-e", #"$|=1; sysopen(my $f,$ARGV[0],O_CREAT|O_RDWR,0600) or die $!; flock($f,LOCK_EX) or die $!; print "R"; <STDIN>;"#,
                           try StoreProcessLock.sidecar(resolved, purpose: "writer").path]
        child.standardOutput = output; child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let ready: Data? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try output.fileHandleForReading.read(upToCount: 1)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        #expect(ready == Data("R".utf8))
        let events = AsyncStream<Void>.makeStream()
        let waiting = Task {
            try await StoreProcessLock.acquire(resolved, contended: { events.continuation.yield(()) })
        }
        var observer = events.stream.makeAsyncIterator()
        _ = await observer.next()
        child.terminate()
        let lease = try await waiting.value
        lease.release()
        events.continuation.finish()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { child.waitUntilExit(); continuation.resume() }
        }
    }
    #endif
}
