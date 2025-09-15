//
//  MigrationV1MappingModel.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//


//
//  MigrationV1MappingModel.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData

/// Costruisce un mapping model custom per la migrazione V1.
/// Qui agganciamo le nostre MigrationPolicy alle entità che contengono `object`.
enum MigrationV1MappingModel {
    
    static func create() -> NSMappingModel {
        let mappingModel = NSMappingModel()
        
        // Entity -> Entity mapping
        let entityMapping = NSEntityMapping()
        entityMapping.name = "ManagedEntity"
        entityMapping.sourceEntityName = "ManagedEntity"
        entityMapping.destinationEntityName = "ManagedEntity"
        entityMapping.mappingType = .copyEntityMappingType
        // No policy, campi diretti
        
        // EntityProperty -> EntityProperty mapping
        let entityPropertyMapping = NSEntityMapping()
        entityPropertyMapping.name = "ManagedEntityProperty"
        entityPropertyMapping.sourceEntityName = "ManagedEntityProperty"
        entityPropertyMapping.destinationEntityName = "ManagedEntityProperty"
        entityPropertyMapping.mappingType = .customEntityMappingType
        entityPropertyMapping.entityMigrationPolicyClassName = NSStringFromClass(MigrationV1EntityPropertyPolicy.self)
        
        // RelationshipProperty -> RelationshipProperty mapping
        let relationshipPropertyMapping = NSEntityMapping()
        relationshipPropertyMapping.name = "ManagedRelationshipProperty"
        relationshipPropertyMapping.sourceEntityName = "ManagedRelationshipProperty"
        relationshipPropertyMapping.destinationEntityName = "ManagedRelationshipProperty"
        relationshipPropertyMapping.mappingType = .customEntityMappingType
        relationshipPropertyMapping.entityMigrationPolicyClassName = NSStringFromClass(MigrationV1RelationshipPropertyPolicy.self)
        
        // ActionProperty -> ActionProperty mapping
        let actionPropertyMapping = NSEntityMapping()
        actionPropertyMapping.name = "ManagedActionProperty"
        actionPropertyMapping.sourceEntityName = "ManagedActionProperty"
        actionPropertyMapping.destinationEntityName = "ManagedActionProperty"
        actionPropertyMapping.mappingType = .customEntityMappingType
        actionPropertyMapping.entityMigrationPolicyClassName = NSStringFromClass(MigrationV1ActionPropertyPolicy.self)
        
        // Tag, Group, Action, and Relationship mappings (copy type, no custom policy)
        let tagMapping = NSEntityMapping()
        tagMapping.name = "ManagedEntityTag"
        tagMapping.sourceEntityName = "ManagedEntityTag"
        tagMapping.destinationEntityName = "ManagedEntityTag"
        tagMapping.mappingType = .copyEntityMappingType

        let groupMapping = NSEntityMapping()
        groupMapping.name = "ManagedEntityGroup"
        groupMapping.sourceEntityName = "ManagedEntityGroup"
        groupMapping.destinationEntityName = "ManagedEntityGroup"
        groupMapping.mappingType = .copyEntityMappingType

        let actionMapping = NSEntityMapping()
        actionMapping.name = "ManagedAction"
        actionMapping.sourceEntityName = "ManagedAction"
        actionMapping.destinationEntityName = "ManagedAction"
        actionMapping.mappingType = .copyEntityMappingType

        let actionTagMapping = NSEntityMapping()
        actionTagMapping.name = "ManagedActionTag"
        actionTagMapping.sourceEntityName = "ManagedActionTag"
        actionTagMapping.destinationEntityName = "ManagedActionTag"
        actionTagMapping.mappingType = .copyEntityMappingType

        let actionGroupMapping = NSEntityMapping()
        actionGroupMapping.name = "ManagedActionGroup"
        actionGroupMapping.sourceEntityName = "ManagedActionGroup"
        actionGroupMapping.destinationEntityName = "ManagedActionGroup"
        actionGroupMapping.mappingType = .copyEntityMappingType

        let relationshipMapping = NSEntityMapping()
        relationshipMapping.name = "ManagedRelationship"
        relationshipMapping.sourceEntityName = "ManagedRelationship"
        relationshipMapping.destinationEntityName = "ManagedRelationship"
        relationshipMapping.mappingType = .copyEntityMappingType

        let relationshipTagMapping = NSEntityMapping()
        relationshipTagMapping.name = "ManagedRelationshipTag"
        relationshipTagMapping.sourceEntityName = "ManagedRelationshipTag"
        relationshipTagMapping.destinationEntityName = "ManagedRelationshipTag"
        relationshipTagMapping.mappingType = .copyEntityMappingType

        let relationshipGroupMapping = NSEntityMapping()
        relationshipGroupMapping.name = "ManagedRelationshipGroup"
        relationshipGroupMapping.sourceEntityName = "ManagedRelationshipGroup"
        relationshipGroupMapping.destinationEntityName = "ManagedRelationshipGroup"
        relationshipGroupMapping.mappingType = .copyEntityMappingType

        mappingModel.entityMappings = [
            entityMapping,
            entityPropertyMapping,
            relationshipPropertyMapping,
            actionPropertyMapping,
            tagMapping,
            groupMapping,
            actionMapping,
            actionTagMapping,
            actionGroupMapping,
            relationshipMapping,
            relationshipTagMapping,
            relationshipGroupMapping
        ]
        
        return mappingModel
    }
}
