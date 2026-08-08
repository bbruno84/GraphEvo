//
//  GraphDedupEngine.swift
//  Graph
//
//  Created by Valerio Buriani on 08/10/25.
//


import Foundation
import CoreData

/// Gestisce la deduplicazione di un Graph in base a un dizionario `uuidFieldMap`.
/// Compares entities of the same type and logical UUID, then merges or removes duplicates.
/// It is intended to run after a baseline → live merge.
public enum GraphDedupEngine {

    // MARK: - Public API

    /// Performs deduplication within a graph.
    ///
    /// - Parameters:
    ///   - graph: The graph to deduplicate.
    ///   - uuidFieldMap: Mappa `entityType` → campo UUID logico nel payload.
    ///   - discriminator: Strategy that decides which entity to keep.
    /// - Throws: Eventuali errori di Core Data.
    public static func deduplicate(
        in graph: Graph,
        uuidFieldMap: [String: String],
        discriminator: DedupDiscriminator
    ) throws {
        guard let context = graph.managedObjectContext else {
            throw NSError(domain: "GraphDedupEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing NSManagedObjectContext in Graph"
            ])
        }

        var caughtError: Error?
        context.performAndWait {
            do {
                // 1️⃣ Load all entities.
                let allEntities = Search<Entity>(graph: graph).where(.type("*")).sync()

                // 2️⃣ Group by logical UUID.
                let grouped = groupEntitiesByUUID(allEntities, uuidFieldMap: uuidFieldMap)
                var removed = 0
                var merged = 0
                var replacementByEntityID: [String: Entity] = [:]
                var entitiesToDelete: [Entity] = []

                // 3️⃣ Choose all survivors before deleting nodes.
                // Relationships are rewritten later with a global duplicate map.
                for (_, entities) in grouped where entities.count > 1 {
                    let survivor = chooseSurvivor(from: entities, discriminator: discriminator)
                    for duplicate in entities where duplicate.id != survivor.id {
                        mergeMetadata(from: duplicate, into: survivor)
                        replacementByEntityID[duplicate.id] = survivor
                        entitiesToDelete.append(duplicate)
                        merged += 1
                    }
                }

                // 4️⃣ Rewrite relationships before deleting duplicates.
                // This avoids relationships pointing to endpoints about to be deleted.
                let allRelationships = Search<Relationship>(graph: graph).where(.type("*")).sync()
                var rewiredRelationships = 0
                for relationship in allRelationships {
                    guard let subject = relationship.subject,
                          let object = relationship.object else {
                        continue
                    }

                    let canonicalSubject = replacementByEntityID[subject.id] ?? subject
                    let canonicalObject = replacementByEntityID[object.id] ?? object

                    guard canonicalSubject.id != subject.id || canonicalObject.id != object.id else {
                        continue
                    }

                    if !relationshipExists(
                        type: relationship.type,
                        subject: canonicalSubject,
                        object: canonicalObject
                    ) {
                        let newRelationship = canonicalSubject.is(relationship: relationship.type)
                        newRelationship.object = canonicalObject
                        copyMetadata(from: relationship, to: newRelationship)
                        rewiredRelationships += 1
                    }

                    relationship.delete()
                }

                // 5️⃣ Deduplicate identical relationships already present among survivors.
                let remainingRelationships = Search<Relationship>(graph: graph).where(.type("*")).sync()
                var seenRelationships = Set<RelationshipKey>()
                for relationship in remainingRelationships {
                    guard let subject = relationship.subject,
                          let object = relationship.object else {
                        continue
                    }

                    let key = RelationshipKey(type: relationship.type, subjectID: subject.id, objectID: object.id)
                    if seenRelationships.contains(key) {
                        relationship.delete()
                    } else {
                        seenRelationships.insert(key)
                    }
                }

                // 6️⃣ It is now safe to delete duplicate entities.
                for duplicate in entitiesToDelete {
                    duplicate.delete()
                    removed += 1
                }

                try context.save()
                GraphMigrationLogger.log(
                    migrationID: "GraphDedupEngine",
                    phase: .ready,
                    level: .info,
                    event: "dedup_completed",
                    message: "Graph dedup completed",
                    metadata: [
                        "merged": String(merged),
                        "removed": String(removed),
                        "rewiredRelationships": String(rewiredRelationships),
                        "totalEntities": String(allEntities.count)
                    ],
                    configuration: graph.configuration
                )

            } catch {
                GraphMigrationLogger.log(
                    migrationID: "GraphDedupEngine",
                    phase: .ready,
                    level: .error,
                    event: "dedup_failed",
                    message: error.localizedDescription,
                    configuration: graph.configuration
                )
                caughtError = error
            }
        }
        if let caughtError {
            throw caughtError
        }
    }

    // MARK: - Helpers

    private struct EntityKey: Hashable {
        let type: String
        let uuid: String
    }

    private struct RelationshipKey: Hashable {
        let type: String
        let subjectID: String
        let objectID: String
    }

    /// Groups entities by logical UUID (using `uuidFieldMap`).
    private static func groupEntitiesByUUID(
        _ entities: [Entity],
        uuidFieldMap: [String: String]
    ) -> [EntityKey: [Entity]] {
        var dict = [EntityKey: [Entity]]()
        for entity in entities {
            if let key = entityKey(for: entity, using: uuidFieldMap) {
                dict[key, default: []].append(entity)
            }
        }
        return dict
    }

    private static func chooseSurvivor(from entities: [Entity], discriminator: DedupDiscriminator) -> Entity {
        var survivor = entities.first!
        for candidate in entities.dropFirst() {
            survivor = discriminator.choosePreferred(survivor, candidate)
        }
        return survivor
    }

    /// Copies properties, tags, and groups without touching relationships.
    private static func mergeMetadata(from source: Entity, into target: Entity) {
        for (k, v) in source.properties {
            if target.properties[k] == nil {
                target[dynamicMember: k] = v
            }
        }

        for tag in source.tags where !target.tags.contains(tag) {
            target.add(tags: tag)
        }

        for group in source.groups where !target.groups.contains(group) {
            target.add(to: group)
        }
    }

    private static func relationshipExists(type: String, subject: Entity, object: Entity) -> Bool {
        subject.relationshipsWhenSubject.contains { relationship in
            guard let existingObject = relationship.object else { return false }
            return relationship.type == type && existingObject.id == object.id
        }
    }

    private static func copyMetadata(from source: Relationship, to target: Relationship) {
        for (key, value) in source.properties {
            target[dynamicMember: key] = value
        }

        for tag in source.tags where !target.tags.contains(tag) {
            target.add(tags: tag)
        }

        for group in source.groups where !target.groups.contains(group) {
            target.add(to: group)
        }
    }

    /// Estrae l’UUID logico dal payload.
    private static func entityKey(for entity: Entity, using uuidFieldMap: [String: String]) -> EntityKey? {
        guard let field = uuidFieldMap[entity.type],
              let value = entity[dynamicMember: field] as? String else {
            return nil
        }
        return EntityKey(type: entity.type, uuid: value)
    }
}
