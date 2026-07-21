//
//  GraphMergeEngine.swift
//  Graph
//
//  Created by Valerio Buriani on 08/10/25.
//


import Foundation
import CoreData

/// Engine per fondere due grafi compatibili (es. baseline → live).
/// Esegue un merge completo in due passaggi:
///   1. Copia di tutte le Entity (nuove nel primary)
///   2. Ricostruzione di relazioni e azioni
///
/// Tutte le nuove Entity vengono contrassegnate con un campo `source`,
/// che può essere utilizzato in fase di dedup per discriminare l'origine.
public enum GraphMergeEngine {
    private struct EntityKey: Hashable {
        let type: String
        let uuid: String
    }

    public struct GraphMergeReport {
        public let importedEntities: Int
        public let mappedEntities: Int
        public let unmappedEntities: Int
        public let recreatedRelationships: Int
        public let skippedRelationships: Int
        public let recreatedActions: Int
        public let skippedActions: Int
    }

    // MARK: - Public API

    /// Esegue il merge da un Graph secondario (es. baseline migrato)
    /// in un Graph primario (es. store live).
    ///
    /// - Parameters:
    ///   - secondaryGraph: Il grafo sorgente da cui importare i dati.
    ///   - primaryGraph: Il grafo di destinazione in cui importare.
    ///   - uuidFieldMap: Mappa che associa `entityType` → nome del campo UUID nel payload.
    ///   - sourceTag: Etichetta di origine, salvata come `entity["source"]`.
    /// - Throws: Propaga eventuali errori Core Data o di mapping.
    @discardableResult
    public static func merge(
        from secondaryGraph: Graph,
        into primaryGraph: Graph,
        uuidFieldMap: [String: String],
        sourceTag: String,
        migrationID: String = "GraphMergeEngine"
    ) throws -> GraphMergeReport {
        guard let primaryContext = primaryGraph.managedObjectContext,
              let secondaryContext = secondaryGraph.managedObjectContext else {
            throw NSError(domain: "GraphMergeEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing NSManagedObjectContext in one of the graphs"
            ])
        }

        var report = GraphMergeReport(
            importedEntities: 0,
            mappedEntities: 0,
            unmappedEntities: 0,
            recreatedRelationships: 0,
            skippedRelationships: 0,
            recreatedActions: 0,
            skippedActions: 0
        )
        primaryContext.performAndWait {
            secondaryContext.performAndWait {
                let secondaryEntities = Search<Entity>(graph: secondaryGraph)
                        .where(.type("*"))
                        .sync()

                    // Mappa type+UUID → nuova entity nel primary.
                    // Il solo UUID può collidere tra tipi diversi.
                    var importMap: [EntityKey: Entity] = [:]
                    var importedEntities = 0
                    var unmappedEntities = 0

                    // Pass 1 — Copia entità
                    for src in secondaryEntities {
                        let newEntity = Entity(src.type, graph: primaryGraph)
                        copyMetadata(from: src, to: newEntity)
                        importedEntities += 1

                        // Copia UUID logico
                        if let uuidField = uuidFieldMap[src.type],
                           let uuidValue = src[dynamicMember: uuidField] {
                            newEntity[dynamicMember: uuidField] = uuidValue
                        }

                        newEntity[dynamicMember: "source"] = sourceTag
                        if let key = entityKey(for: src, using: uuidFieldMap) {
                            importMap[key] = newEntity
                        } else {
                            newEntity[dynamicMember: "migrationUnmapped"] = true
                            newEntity[dynamicMember: "migrationUnmappedReason"] = "missing uuid field"
                            unmappedEntities += 1
                        }
                    }

                    // Pass 2 — Ricrea relazioni e azioni
                    var relCount = 0
                    var actCount = 0
                    var skippedRelCount = 0
                    var skippedActCount = 0

                    for src in secondaryEntities {
                        guard let sourceKey = entityKey(for: src, using: uuidFieldMap),
                              let mappedSource = importMap[sourceKey] else {
                            skippedRelCount += src.relationshipsWhenSubject.count
                            skippedActCount += src.actionsWhenSubject.count
                            continue
                        }

                        // Relazioni come soggetto
                        for rel in src.relationshipsWhenSubject {
                            guard let objectKey = rel.object.flatMap({ entityKey(for: $0, using: uuidFieldMap) }),
                                  let mappedObject = importMap[objectKey] else {
                                skippedRelCount += 1
                                continue
                            }
                            let newRel = mappedSource.is(relationship: rel.type)
                            newRel.object = mappedObject
                            newRel[dynamicMember: "source"] = sourceTag
                            relCount += 1
                        }

                        // Azioni come soggetto
                        for act in src.actionsWhenSubject {
                            let newAction = mappedSource.will(action: act.type)
                            newAction[dynamicMember: "source"] = sourceTag
                            for obj in act.objects {
                                if let objectKey = entityKey(for: obj, using: uuidFieldMap),
                                   let mappedObj = importMap[objectKey] {
                                    newAction.add(objects: mappedObj)
                                } else {
                                    skippedActCount += 1
                                }
                            }
                            actCount += 1
                        }
                    }

                primaryGraph.sync()
                report = GraphMergeReport(
                    importedEntities: importedEntities,
                    mappedEntities: importMap.count,
                    unmappedEntities: unmappedEntities,
                    recreatedRelationships: relCount,
                    skippedRelationships: skippedRelCount,
                    recreatedActions: actCount,
                    skippedActions: skippedActCount
                )
            }
        }

        GraphMigrationLogger.log(
            migrationID: migrationID,
            phase: .ready,
            level: report.skippedRelationships > 0 || report.unmappedEntities > 0 ? .warning : .info,
            event: "merge_completed",
            message: "Graph merge completed",
            metadata: [
                "importedEntities": String(report.importedEntities),
                "mappedEntities": String(report.mappedEntities),
                "unmappedEntities": String(report.unmappedEntities),
                "recreatedRelationships": String(report.recreatedRelationships),
                "skippedRelationships": String(report.skippedRelationships),
                "recreatedActions": String(report.recreatedActions),
                "skippedActions": String(report.skippedActions)
            ],
            configuration: primaryGraph.configuration
        )
        return report
    }

    // MARK: - Helpers

    /// Copia properties, tags e groups da una Entity all'altra.
    private static func copyMetadata(from source: Entity, to target: Entity) {
        for (key, value) in source.properties {
            target[dynamicMember: key] = value
        }
        for tag in source.tags {
            target.add(tags: tag)
        }
        for group in source.groups {
            target.add(to: group)
        }
    }

    /// Estrae il valore UUID logico dal payload di una entity.
    private static func uuidValue(for entity: Entity, using uuidFieldMap: [String: String]) -> String? {
        guard let field = uuidFieldMap[entity.type],
              let value = entity[dynamicMember: field] as? String else {
            return nil
        }
        return value
    }

    private static func entityKey(for entity: Entity, using uuidFieldMap: [String: String]) -> EntityKey? {
        guard let uuid = uuidValue(for: entity, using: uuidFieldMap) else {
            return nil
        }
        return EntityKey(type: entity.type, uuid: uuid)
    }
}
