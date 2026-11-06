import Foundation
import GraphEvo

/// Compiles the public App Group surface without requiring a signed test runner.
@available(macOS 14, *)
func compilePublicAppGroupSurface(identifier: String, graphID: GraphID) async throws {
    let primary = try GraphContext(appGroup: .init(identifier: identifier, role: .primary))
    try await primary.createAppGroupGraph(id: graphID).close()
    let graph = try await primary.openAppGroupGraph(id: graphID)
    try await graph.close()
    let secondary = try GraphContext(appGroup: .init(identifier: identifier, role: .secondary,
        secondaryAccess: .readWrite, diagnosticLabel: "Consumer"))
    let read: GraphAppGroupOperationResult<Int> = try await secondary.readAppGroupGraph(id: graphID) { _ in 0 }
    let write: GraphAppGroupOperationResult<Int> = try await secondary.transactionAppGroupGraph(id: graphID) { _ in read.value }
    _ = write.closePending
}

/// A separate process provides a stopped v1 source using only the public legacy API.
@MainActor func seedPublicV1Source(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let graph = Graph(storeURL: url, migrationEnabled: false)
    guard graph.isReady else { throw GraphStoreError.missingStore }
    let item = Entity("Legacy.Public", graph: graph)
    item[dynamicMember: "binary"] = Data([0, 128, 255])
    item[dynamicMember: "array"] = ["one", "two"]
    item[dynamicMember: "dictionary"] = ["flag": true]
    item[dynamicMember: "codable"] = try GraphArchiver.archive(AnyCodableObject(["nested": AnyCodableObject([1, 2, 3])]))
    var failure: (any Error)?
    graph.sync { success, error in if !success { failure = error ?? GraphStoreError.missingStore } }
    if let failure { throw failure }
}

@available(macOS 14, *)
func checkPublicCoordinatedContext(at root: URL) async throws {
    let context = GraphContext(), other = GraphContext(), id = GraphID(), url = root.appendingPathComponent("Coordinated.sqlite")
    let graph = try await context.createGraph(id: id, at: url)
    let node = graph.makeNodeID()
    try await graph.transaction { try $0.insert(GraphRecord(id: node, type: "Public", properties: ["body": .data(Data([4, 5]))])) }
    let observer = try await graph.changes()
    var changes = observer.makeAsyncIterator()
    guard await changes.next() != nil else { throw GraphModelError.invalidValue }
    observer.cancel()
    guard try await graph.cloudAccountState == .localOnly else { throw GraphModelError.invalidValue }
    try await context.setForegroundActive(true)
    try await context.refreshCloudAccounts()
    do {
        _ = try await other.openGraph(id: id, at: url)
        throw GraphModelError.invalidValue
    } catch GraphStoreError.ownershipConflict { }
    try await graph.close()
    let reopened = try await other.openGraph(id: id, at: url)
    guard try await reopened.read({ try $0.record(for: node)?.properties["body"] }) == .data(Data([4, 5])) else { throw GraphModelError.invalidValue }
    try await reopened.close()

    let source = root.appendingPathComponent("PublicV1.sqlite")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--seed-coordinated-v1", source.path]
    try child.run(); child.waitUntilExit()
    guard child.terminationStatus == 0 else { throw GraphModelError.invalidValue }
    let request = GraphV1BootstrapRequest(sourceURL: source, destinationURL: root.appendingPathComponent("PublicV2.sqlite"),
        graphID: GraphID(), operationID: UUID(), backupRoot: root.appendingPathComponent("PublicBackups"), reason: "Public Swift 6 consumer")
    let result = try await context.openGraph(convertingLocalV1: request), converted = try result.opening.get()
    guard let convertedID = result.conversion.receipt.nodeIDs.values.first,
          result.conversion.receipt.nodeIDs.count == 1,
          try await converted.read({ try $0.record(for: convertedID)?.properties["binary"] }) == .data(Data([0, 128, 255])) else { throw GraphModelError.invalidValue }
    try await converted.close()
    let recovered = try await context.openGraph(convertingLocalV1: request)
    guard recovered.conversion.receipt == result.conversion.receipt else { throw GraphModelError.invalidValue }
    try await recovered.opening.get().close()
    print("PASS public coordinated contexts and staged v1 bootstrap: Swift 6, no package imports or native adapters.")
}

/// Compile the complete cloud/activation surface without opening a real account in CI.
@available(macOS 14, *)
func compilePublicCloudSurface(context: GraphContext, graph: GraphStore, connection: GraphCloudConnection,
                               replicaURL: URL, declaration: GraphCloudCutoverDeclaration) async throws {
    let observation: GraphObservation<GraphCloudConnectionState> = try await connection.observeState()
    observation.cancel()
    try await connection.retry()
    try await connection.bindPrivateGraph(graph, zoneName: "Public")
    try await context.setForegroundActive(true)
    try await connection.requestSynchronization()
    try await connection.notifyRemoteChanges(in: .private)
    try await connection.pauseSynchronization(for: graph.id)
    try await connection.resumeSynchronization(for: graph.id)
    let _: GraphCloudActivationStatus = try await connection.prepareActivation(for: graph.id, activationID: UUID(), zoneName: "Public", declaration: declaration)
    let _: GraphCloudActivationResult = try await connection.advanceActivation(for: graph.id)
    let _: GraphCloudActivationStatus? = try await connection.activationStatus(for: graph.id)
    let _: GraphCloudReplicaResult = try await connection.openReplica(id: graph.id, at: replicaURL, zoneName: "Public")
    try await connection.close()
}

/// Compiles native invitation and lifecycle APIs without live CloudKit side effects.
@available(macOS 14, *)
func compilePublicSharingSurface(connection: GraphCloudConnection, graph: GraphStore, url: URL) async throws {
    let presentation: GraphCloudSharingPresentation = try await connection.prepareSharing(for: graph, title: "Shared graph")
    try await presentation.close()
    let join: GraphCloudJoin = try await connection.acceptInvitation(at: url)
    let _: GraphCloudJoinState = try await join.state
    let progress = try await join.observeState(); progress.cancel()
    try await join.retry()
    let _: [GraphCloudJoin] = try await connection.pendingInvitations()
    let replica = try await connection.openReplica(for: join, at: url)
    try await replica.close()
    let participants: [GraphCloudParticipant] = try await connection.participants(in: graph)
    if let participant = participants.first?.id {
        let _: GraphCloudSharingStatus = try await connection.setPermission(.readOnly, for: participant, in: graph)
        let _: GraphCloudSharingStatus = try await connection.removeParticipant(participant, from: graph)
    }
    let status = try await connection.observeSharing(for: graph.id); status.cancel()
    let _: GraphCloudSharingStatus = try await connection.sharingStatus(for: graph.id)
    let _: GraphCloudSharingStatus = try await connection.refreshSharing(for: graph.id)
    try await connection.registerSharedReplica(id: graph.id, at: url)
    let _: GraphCloudSharingStatus = try await connection.stopSharing(graph)
    let _: GraphCloudSharingStatus = try await connection.leaveSharedGraph(graph)
    try await connection.discardInvitation(join)
}
