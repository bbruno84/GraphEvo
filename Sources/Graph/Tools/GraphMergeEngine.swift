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
    public static func merge(
        from secondaryGraph: Graph,
        into primaryGraph: Graph,
        uuidFieldMap: [String: String],
        sourceTag: String
    ) throws {
        guard let primaryContext = primaryGraph.managedObjectContext,
              let secondaryContext = secondaryGraph.managedObjectContext else {
            throw NSError(domain: "GraphMergeEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing NSManagedObjectContext in one of the graphs"
            ])
        }

        print("[GraphMergeEngine] 🚀 Avvio merge baseline → live")
        primaryContext.performAndWait {
            secondaryContext.performAndWait {
                do {
                    let secondaryEntities = Search<Entity>(graph: secondaryGraph)
                        .where(.type("*"))
                        .sync()

                    print("[GraphMergeEngine] 📦 Importing \(secondaryEntities.count) entities...")

                    // Mappa UUID → nuova entity nel primary
                    var importMap: [String: Entity] = [:]

                    // Pass 1 — Copia entità
                    for src in secondaryEntities {
                        let newEntity = Entity(src.type, graph: primaryGraph)
                        copyMetadata(from: src, to: newEntity)

                        // Copia UUID logico
                        if let uuidField = uuidFieldMap[src.type],
                           let uuidValue = src[dynamicMember: uuidField] {
                            newEntity[dynamicMember: uuidField] = uuidValue
                        }

                        newEntity[dynamicMember: "source"] = sourceTag
                        if let key = uuidValue(for: src, using: uuidFieldMap) {
                            importMap[key] = newEntity
                        }
                    }

                    print("[GraphMergeEngine] ✅ Pass 1 completato: \(importMap.count) entità importate")

                    // Pass 2 — Ricrea relazioni e azioni
                    var relCount = 0
                    var actCount = 0

                    for src in secondaryEntities {
                        guard let mappedSource = importMap[uuidValue(for: src, using: uuidFieldMap) ?? ""] else { continue }

                        // Relazioni come soggetto
                        for rel in src.relationshipsWhenSubject {
                            guard let objectUUID = rel.object.flatMap({ uuidValue(for: $0, using: uuidFieldMap) }),
                                  let mappedObject = importMap[objectUUID] else { continue }
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
                                if let objUUID = uuidValue(for: obj, using: uuidFieldMap),
                                   let mappedObj = importMap[objUUID] {
                                    newAction.add(objects: mappedObj)
                                }
                            }
                            actCount += 1
                        }
                    }

                    print("[GraphMergeEngine] 🔗 Relazioni ricreate: \(relCount), Azioni ricreate: \(actCount)")
                    primaryGraph.sync()

                } catch {
                    print("[GraphMergeEngine] ❌ Errore durante il merge: \(error)")
                }
            }
        }

        print("[GraphMergeEngine] 🎯 Merge completato con successo.")
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
}
