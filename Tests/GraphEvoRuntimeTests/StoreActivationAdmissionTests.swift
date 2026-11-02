import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreActivationAdmissionTests {
    @Test func restrictionCoversAliasesControlsRemainAvailableAndReleaseIsGenerationBound() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = StoreRegistry(), id = UUID()
        let handle = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("Graph.sqlite"))), schema: fixtureSchema())
        let alias = try await handle.newLease()
        try await handle.restrictActivation(id)
        #expect(try await alias.read { _ in true })
        await #expect { try await alias.transaction { _ in Issue.record("Blocked writer executed") } } throws: {
            if case StoreRuntimeError.writesSuspended = $0 { return true }; return false
        }
        #expect(try await alias.controlTransaction { _ in true })
        await #expect { try await handle.restrictActivation(UUID(), release: true) } throws: {
            if case StoreRuntimeError.resourceReserved = $0 { return true }; return false
        }
        let reservation = try await handle.suspendWrites()
        try await handle.restrictActivation(id, release: true)
        await #expect { try await alias.transaction { _ in true } } throws: {
            if case StoreRuntimeError.writesSuspended = $0 { return true }; return false
        }
        await reservation.release()
        #expect(try await alias.transaction { _ in true })
        try await alias.close(); try await handle.close()
    }

    @Test func peerReadGateIsIndependentOfSharingAndOtherResources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = StoreRegistry(), id = UUID()
        let a = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("A.sqlite"))), schema: fixtureSchema())
        let b = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("B.sqlite"))), schema: fixtureSchema())
        try await a.restrictActivation(id, reads: true)
        await #expect { try await a.read { _ in true } } throws: {
            if case StoreRuntimeError.dataUnavailable = $0 { return true }; return false
        }
        #expect(try await a.controlRead { _ in true })
        #expect(try await b.transaction { _ in true })
        try await a.setDataAvailable(false)
        try await a.restrictActivation(id, release: true)
        await #expect { try await a.read { _ in true } } throws: {
            if case StoreRuntimeError.dataUnavailable = $0 { return true }; return false
        }
        try await a.setDataAvailable(true)
        #expect(try await a.read { _ in true })
        try await a.close(); try await b.close()
    }
}
