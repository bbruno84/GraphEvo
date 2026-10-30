import CloudKit
import CoreData
import Foundation
import GraphEvoRuntime

/// Explicit synthetic-store laboratory. Never used by a public opening or migration path.
@available(iOS 17, macOS 14, *)
final class GraphSchemaMigrationLaboratory {
    enum Layout: String { case v1, native, versioned }
    enum Route { case lightweight, staged, stagedFailure }
    enum Failure: Error { case fixture, replay, missingResponse, deadline, overlap, injected }
    struct Row: Codable, Equatable {
        let kind: String
        let id: String
        let type: String
        let label: String
        let stageOnly: String?
        let bytes: Data
        let tags: [String]
        let groups: [String]
        let date: Date?
        let subjects: [String]
        let objects: [String]
        let graphProjection: String?
        let nodeProjection: String?
        let dataVersion: Int64?
    }
    static let versionKey = "ge2DataVersion"
    private static let ownershipLock = NSLock()
    private static var owners: [String: GraphSchemaMigrationLaboratory] = [:]
    struct NativeEvent: Codable {
        let type: String
        let store: String
        let finished: Bool
        let succeeded: Bool
        let errorDomain: String?
        let errorCode: Int?
    }
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NativeEvent] = []
        func append(_ event: NativeEvent) {
            lock.lock(); defer { lock.unlock() }
            values.append(event)
            if values.count > 256 { values.removeFirst() }
        }
        func snapshot() -> [NativeEvent] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private let eventLog = EventLog()
    private var eventObserver: NSObjectProtocol?
    var nativeEvents: [NativeEvent] { eventLog.snapshot() }
    private let claims: [String]
    private var gateways: [StoreGatewayLease] = []
    let container: NSPersistentContainer
    let run: UUID
    let layout: Layout
    private(set) var handlerEvents: [String] = []
    private(set) var lastNativeOperation = "none"

    static func model(_ layout: Layout) -> NSManagedObjectModel {
        let model = layout == .v1 ? Model.makeModel() : GraphNativeIdentityColumns.makeModel(indexed: true, includingDataVersion: false)
        if layout == .versioned {
            for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
                let attribute = NSAttributeDescription()
                attribute.name = versionKey; attribute.attributeType = .integer64AttributeType; attribute.isOptional = true
                model.entitiesByName[name]!.properties.append(attribute)
            }
        }
        // A laboratory model identifier is not public alpha protocol activation.
        model.versionIdentifiers = ["SchemaMigrationProbe." + layout.rawValue]
        return model
    }

    private init(urls: [URL], run: UUID, layout: Layout, identifier: String?) {
        self.run = run; self.layout = layout
        claims = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let model = Self.model(layout)
        if identifier != nil { container = NSPersistentCloudKitContainer(name: "SchemaMigrationProbe", managedObjectModel: model) }
        else { container = NSPersistentContainer(name: "SchemaMigrationProbe", managedObjectModel: model) }
        let log = eventLog
        eventObserver = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container, queue: nil) { notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
                let error = event.error as NSError?
                log.append(NativeEvent(type: event.type == .setup ? "setup" : event.type == .import ? "import" : "export", store: event.storeIdentifier,
                    finished: event.endDate != nil, succeeded: event.succeeded, errorDomain: error?.domain, errorCode: error?.code))
            }
    }

    static func open(urls: [URL], run: UUID, layout: Layout, identifier: String? = nil,
                     route: Route = .lightweight) async throws -> GraphSchemaMigrationLaboratory {
        guard urls.count == 1 || (urls.count == 2 && identifier != nil), urls.allSatisfy(\.isFileURL),
              Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }).count == urls.count else { throw Failure.fixture }
        GraphValueTransformer.register()
        let owner = GraphSchemaMigrationLaboratory(urls: urls, run: run, layout: layout, identifier: identifier)
        try owner.reserve()
        do {
            owner.gateways = try urls.map { try StoreGatewayLease.legacy(at: $0) }
            let descriptions = try urls.enumerated().map { index, url -> NSPersistentStoreDescription in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let description = NSPersistentStoreDescription(url: url)
                description.shouldAddStoreAsynchronously = false
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
                if let identifier {
                    let cloud = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
                    cloud.databaseScope = index == 0 ? .private : .shared
                    description.cloudKitContainerOptions = cloud
                }
                if route != .lightweight {
                    guard layout == .versioned else { throw Failure.fixture }
                    let source = model(.v1), target = owner.container.managedObjectModel
                    let frozenSource = NSPersistentStoreCoordinator(managedObjectModel: source)
                    _ = try frozenSource.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
                    let stage = NSCustomMigrationStage(migratingFrom: NSManagedObjectModelReference(model: source, versionChecksum: source.versionChecksum),
                        to: NSManagedObjectModelReference(model: target, versionChecksum: target.versionChecksum))
                    stage.willMigrateHandler = { [weak owner] manager, _ in
                        owner?.handlerEvents.append("will")
                        guard let container = manager.container else { throw Failure.missingResponse }
                        try transformStaged(container.newBackgroundContext(), run: run, value: "handler-before", version: nil)
                        if route == .stagedFailure { throw Failure.injected }
                    }
                    stage.didMigrateHandler = { [weak owner] manager, _ in
                        owner?.handlerEvents.append("did")
                        guard let container = manager.container else { throw Failure.missingResponse }
                        try transformStaged(container.newBackgroundContext(), run: run, value: "handler-after", version: 1)
                    }
                    description.setOption(NSStagedMigrationManager([stage]), forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
                }
                return description
            }
            owner.container.persistentStoreDescriptions = descriptions
            // Synchronous native loading collects every per-store result before continuing.
            var errors: [Error] = []
            owner.container.loadPersistentStores { _, error in if let error { errors.append(error) } }
            if let error = errors.first { throw error }
            guard owner.container.persistentStoreCoordinator.persistentStores.count == urls.count else { throw Failure.missingResponse }
            return owner
        } catch {
            // Retain registry ownership if native detachment itself fails.
            do { try await owner.close() } catch { throw error }
            throw error
        }
    }

    func waitForSetup() async throws {
        for _ in 0..<90 {
            if Set(nativeEvents.filter { $0.type == "setup" && $0.finished && $0.succeeded }.map(\.store)).count == container.persistentStoreDescriptions.count { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure.deadline
    }

    private func reserve() throws {
        Self.ownershipLock.lock(); defer { Self.ownershipLock.unlock() }
        guard claims.allSatisfy({ Self.owners[$0] == nil }) else { throw Failure.overlap }
        for claim in claims { Self.owners[claim] = self }
    }

    func close() async throws {
        let context = container.viewContext
        await context.perform { context.reset() }
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        guard container.persistentStoreCoordinator.persistentStores.isEmpty else { throw Failure.fixture }
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver); self.eventObserver = nil }
        gateways.forEach { $0.release() }; gateways.removeAll()
        releaseClaims()
    }

    private func releaseClaims() {
        Self.ownershipLock.lock(); defer { Self.ownershipLock.unlock() }
        for claim in claims where Self.owners[claim] === self { Self.owners.removeValue(forKey: claim) }
    }

    private static func scoped(_ context: NSManagedObjectContext) -> Graph {
        Graph(transactionContext: context, configuration: GraphStoreConfiguration())
    }
    private static func nodes(_ context: NSManagedObjectContext, run: UUID) -> [Node] {
        let graph = scoped(context), prefix = "SM." + run.uuidString + "."
        return (Search<Entity>(graph: graph).where(.type("*")).sync().map { $0 as Node }
            + Search<Relationship>(graph: graph).where(.type("*")).sync().map { $0 as Node }
            + Search<Action>(graph: graph).where(.type("*")).sync().map { $0 as Node }).filter { $0.type.hasPrefix(prefix) }
    }

    func seed() async throws {
        let context = container.newBackgroundContext(), run = self.run
        try await context.perform {
            guard Self.nodes(context, run: run).isEmpty else { throw Failure.replay }
            let graph = Self.scoped(context), prefix = "SM." + run.uuidString + "."
            let a = Entity(prefix + "Root", graph: graph), b = Entity(prefix + "Child", graph: graph)
            let edge = Relationship(prefix + "Edge", graph: graph); edge.subject = a; edge.object = b
            let action = Action(prefix + "Action", graph: graph); action.add(subjects: a); action.add(objects: b)
            for (index, node) in ([a, b, edge, action] as [Node]).enumerated() {
                node[dynamicMember: "fixtureID"] = UUID().uuidString
                node[dynamicMember: "label"] = "baseline-\(index)"
                node[dynamicMember: "stageOnly"] = "baseline"
                node[dynamicMember: "bytes"] = Data([0, 255, UInt8(index), 128])
                node.add(tags: "original"); node.add(to: "schema-lab")
                node.setCreatedDate(Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            }
            try context.save()
        }
    }

    /// Use the migration-owned context through generic native fetches. This isolated
    /// framework adapter must not require Graph's Managed subclasses during a stage.
    private static func transformStaged(_ context: NSManagedObjectContext, run: UUID, value: String, version: Int64?) throws {
        try context.performAndWait {
            var nodes: [NSManagedObject] = []
            for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
                let request = NSFetchRequest<NSManagedObject>(entityName: name)
                request.predicate = NSPredicate(format: "type BEGINSWITH %@", "SM." + run.uuidString + ".")
                nodes += try context.fetch(request)
            }
            guard nodes.count == 4 else { throw Failure.fixture }
            for node in nodes {
                guard let properties = node.value(forKey: "propertySet") as? Set<NSManagedObject>,
                      let label = properties.first(where: { $0.value(forKey: "name") as? String == "label" }),
                      let marker = properties.first(where: { $0.value(forKey: "name") as? String == "stageOnly" }),
                      let id = properties.first(where: { $0.value(forKey: "name") as? String == "fixtureID" })?.value(forKey: "object") as? String else { throw Failure.fixture }
                label.setValue(value, forKey: "object"); marker.setValue(value, forKey: "object")
                if let version {
                    node.setValue(run.uuidString, forKey: GraphNativeIdentityColumns.graphAttribute)
                    node.setValue(id, forKey: GraphNativeIdentityColumns.nodeAttribute)
                    node.setValue(version, forKey: versionKey)
                }
            }
            try context.save()
        }
    }

    /// Ordinary facade writes after native opening, kept separate from staged transformations.
    private static func transform(_ context: NSManagedObjectContext, run: UUID, value: String, version: Int64?) throws {
        try context.performAndWait {
            let nodes = nodes(context, run: run)
            guard nodes.count == 4 else { throw Failure.fixture }
            for node in nodes {
                node[dynamicMember: "label"] = value
                if let version {
                    node.node.setValue(run.uuidString, forKey: GraphNativeIdentityColumns.graphAttribute)
                    node.node.setValue(node[dynamicMember: "fixtureID"] as? String, forKey: GraphNativeIdentityColumns.nodeAttribute)
                    node.node.setValue(version, forKey: versionKey)
                }
            }
            try context.save()
        }
    }
    func transform(value: String, version: Int64) async throws {
        let context = container.newBackgroundContext(), run = self.run
        try await context.perform { try Self.transform(context, run: run, value: value, version: version) }
    }

    func snapshot() async throws -> [Row] {
        let context = container.newBackgroundContext(), run = self.run, layout = self.layout
        return try await context.perform {
            let nodes = Self.nodes(context, run: run)
            return try nodes.map { node in
                func id(_ entity: Entity) throws -> String {
                    guard let value = entity[dynamicMember: "fixtureID"] as? String else { throw Failure.fixture }; return value
                }
                let subjects: [String], objects: [String], kind: String
                if let edge = node as? Relationship {
                    kind = "relationship"; subjects = try edge.subject.map { [try id($0)] } ?? []; objects = try edge.object.map { [try id($0)] } ?? []
                } else if let action = node as? Action {
                    kind = "action"; subjects = try action.subjects.map(id).sorted(); objects = try action.objects.map(id).sorted()
                } else { kind = "entity"; subjects = []; objects = [] }
                guard let identity = node[dynamicMember: "fixtureID"] as? String,
                      let label = node[dynamicMember: "label"] as? String,
                      let bytes = node[dynamicMember: "bytes"] as? Data else { throw Failure.fixture }
                return Row(kind: kind, id: identity, type: node.type, label: label, stageOnly: node[dynamicMember: "stageOnly"] as? String, bytes: bytes,
                    tags: node.tags.sorted(), groups: node.groups.sorted(), date: node.createdDateIfPresent,
                    subjects: subjects, objects: objects,
                    graphProjection: layout == .v1 ? nil : node.node.value(forKey: GraphNativeIdentityColumns.graphAttribute) as? String,
                    nodeProjection: layout == .v1 ? nil : node.node.value(forKey: GraphNativeIdentityColumns.nodeAttribute) as? String,
                    dataVersion: layout == .versioned ? (node.node.value(forKey: Self.versionKey) as? NSNumber)?.int64Value : nil)
            }.sorted { $0.id < $1.id }
        }
    }

    /// Four rows alone are not a complete import: wait for payload, detail rows and endpoints.
    static func completeFixture(_ rows: [Row]) -> Bool {
        guard rows.count == 4, Set(rows.map(\.id)).count == 4,
              let root = rows.first(where: { $0.type.hasSuffix(".Root") }),
              let child = rows.first(where: { $0.type.hasSuffix(".Child") }) else { return false }
        let suffixes = ["Root", "Child", "Edge", "Action"]
        for row in rows {
            guard let index = suffixes.firstIndex(where: { row.type.hasSuffix("." + $0) }),
                  row.bytes == Data([0, 255, UInt8(index), 128]), row.tags == ["original"], row.groups == ["schema-lab"],
                  row.date == Date(timeIntervalSince1970: 1_700_000_000 + Double(index)) else { return false }
            if index < 2 {
                guard row.kind == "entity", row.subjects.isEmpty, row.objects.isEmpty else { return false }
            } else {
                guard row.kind == (index == 2 ? "relationship" : "action"), row.subjects == [root.id], row.objects == [child.id] else { return false }
            }
        }
        return Set(rows.map { $0.type.components(separatedBy: ".").last! }) == Set(suffixes)
    }

    func waitForRows(label: String? = nil, version: Int64? = nil) async throws -> [Row] {
        for _ in 0..<90 {
            if let rows = try? await snapshot(), Self.completeFixture(rows),
               label == nil || rows.allSatisfy({ $0.label == label }),
               version == nil || rows.allSatisfy({ $0.dataVersion == version && $0.graphProjection == run.uuidString && $0.nodeProjection == $0.id }) { return rows }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure.deadline
    }

    func invitation(recipient: String, existingOnly: Bool = false) async throws -> URL {
        guard let container = container as? NSPersistentCloudKitContainer,
              let store = container.persistentStoreCoordinator.persistentStores.first else { throw Failure.fixture }
        let context = container.newBackgroundContext(), run = self.run
        let ids = await context.perform { Self.nodes(context, run: run).map(\.runtimeObjectID) }
        guard ids.count == 4 else { throw Failure.fixture }
        let share: CKShare
        if existingOnly {
            lastNativeOperation = "existing-share-only"
            let existing = try container.fetchShares(matching: ids)
            guard let first = existing.values.first, Set(existing.values.map { $0.recordID }).count == 1 else { throw Failure.missingResponse }
            share = first
        } else {
            guard try container.fetchShares(matching: ids).isEmpty else { throw Failure.replay }
            guard let root = container.persistentStoreDescriptions.first?.url?.deletingLastPathComponent() else { throw Failure.fixture }
            try Data("reserved".utf8).write(to: root.appendingPathComponent("share-assignment-reserved"), options: .withoutOverwriting)
            lastNativeOperation = "share"
            share = try await withCheckedThrowingContinuation { continuation in
                container.performBackgroundTask { context in
                    do {
                        let nodes = try ids.map { try context.existingObject(with: $0) }
                        container.share(nodes, to: nil) { _, share, _, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let share { continuation.resume(returning: share) }
                            else { continuation.resume(throwing: Failure.missingResponse) }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        lastNativeOperation = "participants"
        share.publicPermission = .none
        let participants = try await container.fetchParticipants(matching: [CKUserIdentity.LookupInfo(userRecordID: CKRecord.ID(recordName: recipient))], into: store)
        guard participants.count == 1, let participant = participants.first,
              participant.userIdentity.userRecordID?.recordName == recipient else { throw Failure.fixture }
        participant.role = .privateUser; participant.permission = .readWrite; share.addParticipant(participant)
        lastNativeOperation = "persist-share"
        let saved = try await container.persistUpdatedShare(share, in: store)
        guard let url = saved.url else { throw Failure.missingResponse }; return url
    }

    /// Read-only diagnostic. A missing mapping never permits replaying native assignment.
    func inspectExistingShare() async throws -> Int {
        guard let container = container as? NSPersistentCloudKitContainer else { throw Failure.fixture }
        let context = container.newBackgroundContext(), run = self.run
        let ids = await context.perform { Self.nodes(context, run: run).map(\.runtimeObjectID) }
        lastNativeOperation = "fetch-shares-read-only"
        do {
            let count = try container.fetchShares(matching: ids).count
            lastNativeOperation = "fetch-shares-read-only:count=\(count)"
            return count
        }
        catch {
            let error = error as NSError
            let path = container.persistentStoreDescriptions[0].url!.deletingLastPathComponent().appendingPathComponent("native-diagnostic.txt")
            // Private diagnostic artifact; never put framework descriptions in console reports.
            try? String(describing: error).write(to: path, atomically: true, encoding: .utf8)
            throw error
        }
    }

    func accept(url: URL, identifier: String) async throws {
        guard let container = container as? NSPersistentCloudKitContainer,
              container.persistentStoreCoordinator.persistentStores.count == 2 else { throw Failure.fixture }
        let metadata = try await CKContainer(identifier: identifier).shareMetadata(for: url)
        guard metadata.containerIdentifier == identifier else { throw Failure.fixture }
        if metadata.participantStatus == .accepted { return }
        guard metadata.participantStatus == .pending else { throw Failure.fixture }
        _ = try await container.acceptShareInvitations(from: [metadata], into: container.persistentStoreCoordinator.persistentStores[1])
    }
}
