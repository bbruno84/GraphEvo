//
//  DedupTool.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 12/09/25.
//

import Foundation
import CoreData

/// Protocol defining the decision logic when duplicates are found.
public protocol DedupDiscriminator {
    /// Decide which entity to keep between two duplicates.
    func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity
}

/// Tool to remove duplicates from the Graph store.
///
/// Can be used on the entire database or on single entities
/// (e.g. when they arrive from CloudKit).
public final class DedupTool {
    private let graph: Graph
    private let discriminator: DedupDiscriminator
    
    public init(graph: Graph, discriminator: DedupDiscriminator) {
        self.graph = graph
        self.discriminator = discriminator
    }
    
    /// Deduplicate entities across two Graph instances (for baseline merge use case).
    public static func deduplicateBetween(primaryGraph: Graph, secondaryGraph: Graph, discriminator: DedupDiscriminator, uuidFieldMap: [String: String]) throws {
        let primaryEntities = Search<Entity>(graph: primaryGraph).where(.type("*")).sync()
        let secondaryEntities = Search<Entity>(graph: secondaryGraph).where(.type("*")).sync()
        
        print("[DedupTool] Loaded \(primaryEntities.count) entities from primary graph")
        print("[DedupTool] Loaded \(secondaryEntities.count) entities from secondary graph")
        
        var groupedEntities = [String: (primary: Entity?, secondary: Entity?)]()
        
        func key(for entity: Entity) -> String {
            if let uuidField = uuidFieldMap[entity.type], let uuidValue = entity.properties[uuidField] as? String {
                return uuidValue
            }
            return entity.id
        }
        
        for entity in primaryEntities {
            groupedEntities[key(for: entity), default: (nil, nil)].primary = entity
        }
        for entity in secondaryEntities {
            let entityKey = key(for: entity)
            if let existing = groupedEntities[entityKey] {
                groupedEntities[entityKey] = (existing.primary, entity)
            } else {
                groupedEntities[entityKey] = (nil, entity)
            }
        }
        
        let tool = DedupTool(graph: primaryGraph, discriminator: discriminator)
        var cloneCache: [String: Entity] = [:]
        
        var totalMerged = 0
        var totalCreated = 0
        
        for (id, pair) in groupedEntities {
            let primaryEntity = pair.primary
            let secondaryEntity = pair.secondary
            
            if let _ = primaryEntity, secondaryEntity == nil {
                // Only primary exists, keep as is
            } else if primaryEntity == nil, let secondaryEntity = secondaryEntity {
                // Only secondary exists, create new entity in primary and copy metadata/relationships
                guard let context = primaryGraph.managedObjectContext else {
                    print("[DedupTool] ERROR: Primary graph has no managed object context, cannot create entity for ID \(id)")
                    continue
                }
                let newEntity: Entity
                if let cached = cloneCache[secondaryEntity.id] {
                    newEntity = cached
                } else {
                    let newManagedEntity = ManagedEntity(secondaryEntity.type, managedObjectContext: context)
                    newEntity = Entity(managedNode: newManagedEntity)
                    // NOTE: Entity.id is read-only; cannot force to match the secondary's id here.
                    cloneCache[secondaryEntity.id] = newEntity
                    totalCreated += 1
                }
                tool.copyMetadata(from: secondaryEntity, to: newEntity)
                tool.mergeRelationships(from: secondaryEntity, into: newEntity, cache: &cloneCache)
            } else if let primaryEntity = primaryEntity, let secondaryEntity = secondaryEntity {
                // Both exist, call discriminator
                let preferred = discriminator.choosePreferred(primaryEntity, secondaryEntity)
                if preferred === primaryEntity {
                } else {
                    tool.copyMetadata(from: secondaryEntity, to: primaryEntity, preferred: true)
                    tool.mergeRelationships(from: secondaryEntity, into: primaryEntity, cache: &cloneCache)
                    totalMerged += 1
                }
            }
        }
        
        print("[DedupTool] Deduplication between graphs completed. Total merged entities: \(totalMerged), total new entities created in primary: \(totalCreated)")
        primaryGraph.sync()
    }
    
    /// Deduplicate the entire database.
    public func deduplicateAll(uuidFieldMap: [String: String]) throws {

        let allEntities = Search<Entity>(graph: graph).where(.type("*")).sync()
        
        let grouped = groupEntitiesByUUID(allEntities, uuidFieldMap: uuidFieldMap)
        var cloneCache: [String: Entity] = [:]
        
        for (_, entities) in grouped {
            if entities.count > 1 {
                var preferred = entities[0]
                for entity in entities.dropFirst() {
                    preferred = discriminator.choosePreferred(preferred, entity)
                }
                
                for entity in entities {
                    if entity !== preferred {
                        mergeRelationships(from: entity, into: preferred, cache: &cloneCache)
                        copyMetadata(from: entity, to: preferred)
                        deleteEntity(entity)
                    }
                }
            }
        }
        graph.sync()
    }
    
    /// Deduplicate only a single entity (useful during CloudKit sync).
    public func deduplicateSingle(_ entity: Entity, uuidFieldMap: [String: String]) throws {
        
        let duplicates: [Entity] = Search<Entity>(graph: graph).where(.type("*")).sync().filter {
            if let uuidField = uuidFieldMap[$0.type], let uuidValue = $0.properties[uuidField] as? String,
               let entityUuidField = uuidFieldMap[entity.type], let entityUuidValue = entity.properties[entityUuidField] as? String {
                return uuidValue == entityUuidValue
            } else {
                return $0.id == entity.id
            }
        }
        
        guard duplicates.count > 1 else {
            return
        }
        
        var preferred = duplicates[0]
        for dup in duplicates.dropFirst() {
            preferred = discriminator.choosePreferred(preferred, dup)
        }
        
        var cloneCache: [String: Entity] = [:]
        for dup in duplicates {
            if dup !== preferred {
                mergeRelationships(from: dup, into: preferred, cache: &cloneCache)
                copyMetadata(from: dup, to: preferred)
                deleteEntity(dup)
            }
        }
        graph.sync()
    }
    
    private func groupEntitiesByUUID(_ entities: [Entity], uuidFieldMap: [String: String]) -> [String: [Entity]] {
        var dict = [String: [Entity]]()
        for entity in entities {
            let key: String
            if let uuidField = uuidFieldMap[entity.type], let uuidValue = entity.properties[uuidField] as? String {
                key = uuidValue
            } else {
                key = entity.id
            }
            dict[key, default: []].append(entity)
        }
        return dict
    }
    
    private func mergeEntityMetadata(from source: Entity, into target: Entity) {
        for tag in source.tags {
            if !target.tags.contains(tag) {
                target.add(tags: tag)
            }
        }
        for group in source.groups {
            if !target.groups.contains(group) {
                target.add(to: group)
            }
        }
    }
    
    private func mergeRelationships(
        from source: Entity,
        into target: Entity,
        cache cloneCache: inout [String: Entity]
    ) {
        // 1) Merge base metadata first
        mergeEntityMetadata(from: source, into: target)

        // 2) Ensure we always operate in the primary (target) context
        guard let primaryContext = target.managedNode.managedObjectContext else { return }

        // ---- Relationships where source is SUBJECT ----
        for rel in source.relationshipsWhenSubject {
            guard let obj = rel.object else { continue }
            let objInPrimary = ensureEntityInPrimary(obj, cache: &cloneCache, context: primaryContext)
            if !hasSubjectRelation(target, type: rel.type, to: objInPrimary) {
                let newRel = target.is(relationship: rel.type)
                newRel.object = objInPrimary
                copyMetadata(from: rel, to: newRel)
            }
        }

        // ---- Relationships where source is OBJECT ----
        for rel in source.relationshipsWhenObject {
            guard let subj = rel.subject else { continue }
            let subjInPrimary = ensureEntityInPrimary(subj, cache: &cloneCache, context: primaryContext)
            if !hasObjectRelation(target, type: rel.type, from: subjInPrimary) {
                let newRel = subjInPrimary.is(relationship: rel.type)
                newRel.object = target
                copyMetadata(from: rel, to: newRel)
            }
        }

        // ---- Actions where source is SUBJECT ----
        for action in source.actionsWhenSubject {
            if !hasSubjectAction(target, type: action.type) {
                let newAction = target.will(action: action.type)
                copyMetadata(from: action, to: newAction)
                for obj in action.objects {
                    let objInPrimary = ensureEntityInPrimary(obj, cache: &cloneCache, context: primaryContext)
                    newAction.add(objects: objInPrimary)
                }
            }
        }

        // ---- Actions where source is OBJECT ----
        for action in source.actionsWhenObject {
            if !hasObjectAction(target, type: action.type) {
                let newAction = Action(managedNode: ManagedAction(action.type, managedObjectContext: primaryContext))
                newAction.add(objects: target)
                for subj in action.subjects {
                    let subjInPrimary = ensureEntityInPrimary(subj, cache: &cloneCache, context: primaryContext)
                    newAction.add(subjects: subjInPrimary)
                }
                copyMetadata(from: action, to: newAction)
            }
        }
    }
    
    /// Returns an entity in the primary (target) context corresponding to `entity`.
    /// If `entity` already belongs to the primary context it is returned as-is.
    /// Otherwise a shallow clone is created (properties/tags/groups), memoized, and returned.
    private func ensureEntityInPrimary(_ entity: Entity,
                                       cache: inout [String: Entity],
                                       context: NSManagedObjectContext) -> Entity {
        if entity.managedNode.managedObjectContext === context {
            return entity
        }
        if let cached = cache[entity.id] {
            return cached
        }
        let managedClone = ManagedEntity(entity.type, managedObjectContext: context)
        let clone = Entity(managedNode: managedClone)
        // Copy metadata (properties/tags/groups); relationships/actions are linked by callers as needed.
        copyMetadata(from: entity, to: clone, preferred: true)
        cache[entity.id] = clone
        return clone
    }
    
    private func hasSubjectRelation(_ entity: Entity, type: String, to object: Entity) -> Bool {
        for rel in entity.relationshipsWhenSubject {
            if rel.type == type, let obj = rel.object, obj === object {
                return true
            }
        }
        return false
    }
    
    private func hasObjectRelation(_ entity: Entity, type: String, from subject: Entity) -> Bool {
        for rel in entity.relationshipsWhenObject {
            if rel.type == type, let subj = rel.subject, subj === subject {
                return true
            }
        }
        return false
    }
    
    private func hasSubjectAction(_ entity: Entity, type: String) -> Bool {
        for action in entity.actionsWhenSubject {
            if action.type == type {
                return true
            }
        }
        return false
    }
    
    private func hasObjectAction(_ entity: Entity, type: String) -> Bool {
        for action in entity.actionsWhenObject {
            if action.type == type {
                return true
            }
        }
        return false
    }
    
    private func deleteEntity(_ entity: Entity) {
        entity.delete()
    }
    // Helper to copy properties, tags, and groups from one Node to another
    private func copyMetadata(from source: Node, to target: Node, preferred: Bool = false) {
        for (key, value) in source.properties {
            if target.properties[key] == nil {
                target[dynamicMember: key] = value
            } else if preferred {
                target[dynamicMember: key] = value
            }
        }
        for tag in source.tags {
            if !target.tags.contains(tag) {
                target.add(tags: tag)
            }
        }
        for group in source.groups {
            if !target.groups.contains(group) {
                target.add(to: group)
            }
        }
    }
}
