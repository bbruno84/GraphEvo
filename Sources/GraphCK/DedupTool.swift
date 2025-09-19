//
//  DedupTool.swift
//  GraphCK
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
    public static func deduplicateBetween(primaryGraph: Graph, secondaryGraph: Graph, discriminator: DedupDiscriminator) throws {
        let primaryEntities = Search<Entity>(graph: primaryGraph).where(.type("*")).sync()
        let secondaryEntities = Search<Entity>(graph: secondaryGraph).where(.type("*")).sync()
        
        print("[DedupTool] Loaded \(primaryEntities.count) entities from primary graph")
        print("[DedupTool] Loaded \(secondaryEntities.count) entities from secondary graph")
        
        var groupedEntities = [String: (primary: Entity?, secondary: Entity?)]()
        
        for entity in primaryEntities {
            groupedEntities[entity.id, default: (nil, nil)].primary = entity
        }
        for entity in secondaryEntities {
            if let existing = groupedEntities[entity.id] {
                groupedEntities[entity.id] = (existing.primary, entity)
            } else {
                groupedEntities[entity.id] = (nil, entity)
            }
        }
        
        let tool = DedupTool(graph: primaryGraph, discriminator: discriminator)
        
        var totalMerged = 0
        var totalCreated = 0
        
        for (id, pair) in groupedEntities {
            let primaryEntity = pair.primary
            let secondaryEntity = pair.secondary
            
            if let primaryEntity = primaryEntity, secondaryEntity == nil {
                // Only primary exists, keep as is
            } else if primaryEntity == nil, let secondaryEntity = secondaryEntity {
                // Only secondary exists, create new entity in primary and copy metadata/relationships
                guard let context = primaryGraph.managedObjectContext else {
                    print("[DedupTool] ERROR: Primary graph has no managed object context, cannot create entity for ID \(id)")
                    continue
                }
                let newManagedEntity = ManagedEntity(secondaryEntity.type, managedObjectContext: context)
                let newEntity = Entity(managedNode: newManagedEntity)
                // NOTE: Entity.id is read-only; cannot force to match the secondary's id here.
                tool.copyMetadata(from: secondaryEntity, to: newEntity)
                tool.mergeRelationships(from: secondaryEntity, into: newEntity)
                totalCreated += 1
            } else if let primaryEntity = primaryEntity, let secondaryEntity = secondaryEntity {
                // Both exist, call discriminator
                let preferred = discriminator.choosePreferred(primaryEntity, secondaryEntity)
                if preferred === primaryEntity {
                } else {
                    tool.copyMetadata(from: secondaryEntity, to: primaryEntity, preferred: true)
                    tool.mergeRelationships(from: secondaryEntity, into: primaryEntity)
                    totalMerged += 1
                }
            }
        }
        
        print("[DedupTool] Deduplication between graphs completed. Total merged entities: \(totalMerged), total new entities created in primary: \(totalCreated)")
        primaryGraph.sync()
    }
    
    /// Deduplicate the entire database.
    public func deduplicateAll() throws {

        let allEntities = Search<Entity>(graph: graph).where(.type("*")).sync()
        
        let grouped = groupEntitiesByUUID(allEntities)
        
        for (_, entities) in grouped {
            if entities.count > 1 {
                var preferred = entities[0]
                for entity in entities.dropFirst() {
                    preferred = discriminator.choosePreferred(preferred, entity)
                }
                
                for entity in entities {
                    if entity !== preferred {
                        mergeRelationships(from: entity, into: preferred)
                        copyMetadata(from: entity, to: preferred, preferred: true)
                        deleteEntity(entity)
                    }
                }
            }
        }
        graph.sync()
    }
    
    /// Deduplicate only a single entity (useful during CloudKit sync).
    public func deduplicateSingle(_ entity: Entity) throws {
        
        let duplicates: [Entity] = Search<Entity>(graph: graph).where(.type("*")).sync().filter{$0.id == entity.id}
        
        guard duplicates.count > 1 else {
            return
        }
        
        var preferred = duplicates[0]
        for dup in duplicates.dropFirst() {
            preferred = discriminator.choosePreferred(preferred, dup)
        }
        
        for dup in duplicates {
            if dup !== preferred {
                mergeRelationships(from: dup, into: preferred)
                copyMetadata(from: dup, to: preferred, preferred: true)
                deleteEntity(dup)
            }
        }
        graph.sync()
    }
    
    private func groupEntitiesByUUID(_ entities: [Entity]) -> [String: [Entity]] {
        var dict = [String: [Entity]]()
        for entity in entities {
            let key = entity.id
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
    
    private func mergeRelationships(from source: Entity, into target: Entity) {
        mergeEntityMetadata(from: source, into: target)
        
        // Transfer relationships where source is subject
        for rel in source.relationshipsWhenSubject {
            guard let object = rel.object else { continue }
            if !hasSubjectRelation(target, type: rel.type, to: object) {
                let newRel = target.is(relationship: rel.type)
                newRel.object = object
                copyMetadata(from: rel, to: newRel)
            }
        }
        
        // Transfer relationships where source is object
        for rel in source.relationshipsWhenObject {
            guard let subject = rel.subject else { continue }
            if !hasObjectRelation(target, type: rel.type, from: subject) {
                let newRel = subject.is(relationship: rel.type)
                newRel.object = target
                copyMetadata(from: rel, to: newRel)
            }
        }
        
        // Transfer actions where source is subject
        for action in source.actionsWhenSubject {
            if !hasSubjectAction(target, type: action.type) {
                let newAction = target.will(action: action.type)
                copyMetadata(from: action, to: newAction)
                for obj in action.objects {
                    newAction.add(objects: obj)
                }
            }
        }
        
        // Transfer actions where source is object
        for action in source.actionsWhenObject {
            if !hasObjectAction(target, type: action.type) {
                guard let context = target.managedNode.managedObjectContext else { continue }
                let newAction = Action(managedNode: ManagedAction(action.type, managedObjectContext: context))
                newAction.add(objects: target)
                for subj in action.subjects {
                    newAction.add(subjects: subj)
                }
                copyMetadata(from: action, to: newAction)
            }
        }
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



