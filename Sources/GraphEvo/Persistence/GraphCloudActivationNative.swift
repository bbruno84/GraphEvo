import CloudKit
import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Activation metadata is saved with the runtime's bookkeeping author, never uploaded as a primitive.
enum GraphCloudActivationNative {
    static let key = GraphTypedStoreAdapter.prefix + "cloudActivation"
    static let adapter = GraphCloudActivationAdapter(requiresActivation: { context, id in
        try GraphTypedStoreAdapter.controlRoot(context, id: id)[dynamicMember: GraphV1NativeConversion.receiptKey] != nil
    }, read: read, prepare: prepare, write: write, peer: peer)

    static func read(_ context: NSManagedObjectContext, _ id: GraphID) throws -> GraphCloudActivationDocument? {
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        guard let raw = root[dynamicMember: key] else { return nil }
        guard let data = raw as? Data, data.count <= 5 * 1024 * 1024 else { throw GraphCloudActivationError.invalidState }
        let value = try JSONDecoder().decode(GraphCloudActivationDocument.self, from: data)
        try value.validate(graphID: id)
        let checkpoint = try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init())
        guard value.storeID == checkpoint.state.storeID, value.epoch == checkpoint.state.epoch else {
            throw GraphCloudActivationError.invalidState
        }
        return value
    }

    static func write(_ context: NSManagedObjectContext, _ id: GraphID, _ value: GraphCloudActivationDocument) throws {
        try value.validate(graphID: id)
        let state = try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init()).state
        guard value.storeID == state.storeID, value.epoch == state.epoch else { throw GraphCloudActivationError.invalidState }
        if let prior = try read(context, id) {
            guard prior.binding == value.binding, prior.authority.matches(value.authority), prior.manifest == value.manifest,
                  prior.declaration == value.declaration, prior.limits == value.limits else { throw GraphCloudActivationError.authorityConflict }
            guard prior.phase != .published || value.phase == .published else { throw GraphCloudActivationError.invalidState }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 5 * 1024 * 1024 else { throw GraphCloudActivationError.limitExceeded }
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        root[dynamicMember: key] = bytes
        context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
    }

    static func prepare(_ context: NSManagedObjectContext, _ binding: GraphCloudTransportBinding, _ operation: UUID,
                        _ declaration: GraphCloudCutoverDeclaration, _ limits: GraphCloudActivationLimits) throws -> GraphCloudActivationDocument {
        try declaration.validate(); try limits.validate()
        guard GraphNativePropertyStorage.enabled(context) else { throw GraphCloudActivationError.unavailable }
        let id = binding.route.graphID
        if let existing = try read(context, id) {
            guard existing.authority.activationID == operation, existing.binding == binding,
                  existing.declaration == declaration, existing.limits == limits else { throw GraphCloudActivationError.authorityConflict }
            return existing
        }
        guard binding.route.zone.scope == .private,
              let receipt = try GraphV1NativeConversion.adapter.receipt(context, id),
              try GraphCloudAccessMetadata.access(context, id: id, value: nil) == nil else { throw GraphCloudActivationError.invalidRequest }
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        guard root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] == nil else { throw GraphCloudActivationError.invalidRequest }
        var checkpoint = try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init())
        try GraphSyncCheckpointAdapter.reconcile(context, value: &checkpoint, limits: .init())
        guard receipt.targetStoreID == checkpoint.state.storeID else { throw GraphCloudActivationError.invalidState }
        let session = try GraphTypedStoreAdapter.Session(context, id, database: true, maximumCandidates: 100_000)
        guard session.nodes.count <= limits.maximumRecords else { throw GraphCloudActivationError.limitExceeded }
        var records: [CloudKit.CKRecord] = []
        var remaining = limits.maximumPayloadBytes
        for (nodeID, node) in session.nodes {
            try StoreNativeContext.cancellationCheck(in: context)()
            let value = try session.snapshot(node, id: nodeID, chargingBytes: { count in
                guard count <= remaining else { throw GraphCloudActivationError.limitExceeded }
                remaining -= count
            })
            try session.validate(value)
            records.append(try GraphCloudNodeCodec.encode(value, binding: binding.route, modifiedAt: GraphMutationMetadata.modifiedAt(node)))
        }
        let manifest = try GraphCloudSeedManifest.make(records, binding: binding.route, limits: limits)
        // Every current seed row must be discoverable; a consumed or missing baseline cannot be guessed.
        let saves = Set(checkpoint.state.pending.filter { $0.operation == .save }.map(\.id))
        guard Set(session.nodes.keys).isSubset(of: saves) else { throw GraphSyncError.historyUnavailable }
        try GraphSyncCheckpointAdapter.persist(context, checkpoint)
        struct Commitment: Encodable { let activation: UUID; let receipt: GraphV1ConversionReceipt }
        let authority = GraphCloudAuthority(graphID: id, activationID: operation, seedDigest: try manifest.digest,
            recordCount: manifest.entries.count, conversionCommitment: try GraphCloudFingerprint.of(Commitment(activation: operation, receipt: receipt)))
        let result = GraphCloudActivationDocument(binding: binding, storeID: checkpoint.state.storeID, epoch: checkpoint.state.epoch,
            authority: authority, declaration: declaration, manifest: manifest, limits: limits, phase: .prepared)
        try write(context, id, result)
        return result
    }

    static func peer(_ context: NSManagedObjectContext, _ binding: GraphCloudTransportBinding, _ authority: GraphCloudAuthority,
                     _ limits: GraphCloudActivationLimits) throws -> GraphCloudActivationDocument {
        guard GraphNativePropertyStorage.enabled(context) else { throw GraphCloudActivationError.unavailable }
        let id = binding.route.graphID
        if let existing = try read(context, id) {
            guard existing.peer, existing.authority.matches(authority), existing.binding == binding else {
                throw GraphCloudActivationError.authorityConflict
            }
            return existing
        }
        let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
        guard session.nodes.isEmpty, authority.published,
              try GraphTypedStoreAdapter.controlRoot(context, id: id)[dynamicMember: GraphV1NativeConversion.receiptKey] == nil,
              try GraphCloudAccessMetadata.access(context, id: id, value: nil) == nil else { throw GraphCloudActivationError.invalidRequest }
        var checkpoint = try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init())
        try GraphSyncCheckpointAdapter.reconcile(context, value: &checkpoint, limits: .init())
        guard checkpoint.state.pending.isEmpty else { throw GraphCloudActivationError.invalidRequest }
        try GraphSyncCheckpointAdapter.persist(context, checkpoint)
        let result = GraphCloudActivationDocument(binding: binding, storeID: checkpoint.state.storeID, epoch: checkpoint.state.epoch,
            authority: authority, declaration: nil, manifest: nil, limits: limits, phase: .recovering)
        try write(context, id, result)
        return result
    }
}
