import CloudKit
import Foundation
import GraphEvoModel

/// A verified private graph reference scoped to the discovering account and container.
public struct GraphCloudPrivateGraph: Sendable, Equatable, Identifiable {
    public var id: GraphID { binding.graphID }
    public var zoneName: String { binding.zone.name }
    public let supportsFiles: Bool
    let binding: GraphCloudBinding
    let identity: GraphCloudSessionIdentity
}

public struct GraphCloudPrivateGraphIssue: Sendable, Equatable {
    public let zoneName: String
    public let failure: GraphCloudConnectionFailure
    public let reason: GraphCloudDiscoveryError
}

public struct GraphCloudPrivateGraphDiscovery: Sendable {
    public let graphs: [GraphCloudPrivateGraph]
    public let issues: [GraphCloudPrivateGraphIssue]
}

struct GraphPrivateGraphDescriptor: Sendable {
    let zone: GraphCloudZone
    let archive: Data?
}

struct GraphPrivateGraphService: Sendable {
    let list: @Sendable (GraphCloudConfiguration, String?) async throws -> [GraphPrivateGraphDescriptor]
    let publish: @Sendable (GraphCloudConfiguration, GraphCloudBinding) async throws -> Void
    static let live = Self(list: { config, prefix in
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        let zones = try await database.allRecordZones()
        var values: [GraphPrivateGraphDescriptor] = []
        for native in zones.sorted(by: { $0.zoneID.zoneName < $1.zoneID.zoneName }) {
            try Task.checkCancellation()
            let name = native.zoneID.zoneName
            guard name != CKRecordZone.default().zoneID.zoneName, prefix.map({ name.hasPrefix($0) }) ?? true else { continue }
            let zone = GraphCloudZone(scope: .private, owner: native.zoneID.ownerName, name: name)
            do {
                let record = try await database.record(for: GraphCloudGraphDescriptor.id(in: zone))
                guard let archive = try GraphCloudRecordCodec.archive(record, scope: .private).recordArchive else { throw GraphCloudDiscoveryError.invalidDescriptor }
                values.append(.init(zone: zone, archive: archive.count <= GraphCloudGraphDescriptor.maximumBytes ? archive : nil))
                guard values.count <= config.maximumEvents else { throw GraphCloudDiscoveryError.limitExceeded }
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { continue }
        }
        return values
    }, publish: { config, binding in
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        _ = try await database.save(CKRecordZone(zoneID: GraphCloudGraphDescriptor.id(in: binding.zone).zoneID))
        do {
            let current = try await database.record(for: GraphCloudGraphDescriptor.id(in: binding.zone))
            guard try GraphCloudGraphDescriptor.decode(current, zone: binding.zone, supportsFiles: config.supportsFiles) == binding.graphID else {
                throw GraphCloudDiscoveryError.invalidDescriptor
            }
        } catch let error as CKError where error.code == .unknownItem {
            let record = GraphCloudGraphDescriptor.encode(binding, supportsFiles: config.supportsFiles)
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[record.recordID],
                  try GraphCloudGraphDescriptor.decode(saved.get(), zone: binding.zone, supportsFiles: config.supportsFiles) == binding.graphID else {
                throw GraphCloudDiscoveryError.invalidDescriptor
            }
        }
    })
}

extension GraphCloudSession {
    func discoverPrivateGraphs(prefix: String?) async throws -> GraphCloudPrivateGraphDiscovery {
        guard prefix.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true, let service = privateGraphService else {
            throw GraphCloudConnectionError.invalidConfiguration
        }
        return try await activationControl { _, identity in
            let values = try await service.list(self.configuration, prefix)
            guard values.count <= self.configuration.maximumEvents else { throw GraphCloudDiscoveryError.limitExceeded }
            var graphs: [GraphCloudPrivateGraph] = [], issues: [GraphCloudPrivateGraphIssue] = []
            var ids = Set<GraphID>(), ambiguous = Set<GraphID>()
            for value in values {
                guard value.zone.scope == .private, prefix.map({ value.zone.name.hasPrefix($0) }) ?? true else { throw GraphCloudDiscoveryError.invalidDescriptor }
                do {
                    guard let archive = value.archive, archive.count <= GraphCloudGraphDescriptor.maximumBytes else { throw GraphCloudDiscoveryError.invalidDescriptor }
                    let record = try GraphCloudRecordCodec.restore(archive)
                    let id = try GraphCloudGraphDescriptor.decode(record, zone: value.zone, supportsFiles: self.configuration.supportsFiles)
                    guard ids.insert(id).inserted else { ambiguous.insert(id); throw GraphCloudDiscoveryError.invalidDescriptor }
                    graphs.append(.init(supportsFiles: (record["files"] as? NSNumber)?.boolValue == true,
                        binding: .init(zone: value.zone, graphID: id), identity: identity))
                } catch {
                    issues.append(.init(zoneName: value.zone.name, failure: .init(error),
                        reason: (error as? GraphCloudDiscoveryError) ?? .invalidDescriptor))
                }
            }
            return .init(graphs: graphs.filter { !ambiguous.contains($0.id) }, issues: issues)
        }
    }
    func publishPrivateDescriptor(_ binding: GraphCloudBinding) async throws {
        guard let service = privateGraphService else { return }
        try await activationControl { _, _ in try await service.publish(self.configuration, binding) }
    }
}

@available(iOS 17, macOS 14, *)
extension GraphCloudConnection {
    public func discoverPrivateGraphs(zoneNamePrefix: String? = nil) async throws -> GraphCloudPrivateGraphDiscovery {
        let configuration = try await ready()
        return try await operation { try await owningContext.manager.cloud(configuration).discoverPrivateGraphs(prefix: zoneNamePrefix) }
    }
    public func openPrivateGraph(_ reference: GraphCloudPrivateGraph, at storeURL: URL) async throws -> GraphStore {
        try await owningContext.requireOrdinaryContext()
        try GraphContext.validateStoreURL(storeURL)
        let configuration = try await ready()
        let graph = try await operation {
            try await owningContext.manager.openPrivateGraph(reference, at: storeURL, configuration: configuration)
        }
        await graph.retainPublicContext(owningContext, identity: owningContext.identityForBootstrap)
        return graph
    }
}
