//
//  GraphDedupEngine.swift
//  Graph
//
//  Created by Valerio Buriani on 08/10/25.
//


import Foundation
import CoreData

/// Gestisce la deduplicazione di un Graph in base a un dizionario `uuidFieldMap`.
/// Confronta le Entity dello stesso tipo con lo stesso UUID logico e unisce o elimina i duplicati.
/// È pensato come fase successiva al merge baseline → live.
public enum GraphDedupEngine {

    // MARK: - Public API

    /// Esegue la deduplicazione interna al grafo.
    ///
    /// - Parameters:
    ///   - graph: Il grafo in cui deduplicare.
    ///   - uuidFieldMap: Mappa `entityType` → campo UUID logico nel payload.
    ///   - discriminator: Strategia che decide quale Entity mantenere.
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

        print("[GraphDedupEngine] 🚀 Avvio deduplicazione in \(graph.configuration.name ?? "graph")")

        context.performAndWait {
            do {
                // 1️⃣ Carica tutte le Entity
                let allEntities = Search<Entity>(graph: graph).where(.type("*")).sync()
                print("[GraphDedupEngine] 📦 \(allEntities.count) entità totali trovate")

                // 2️⃣ Raggruppa per UUID logico
                let grouped = groupEntitiesByUUID(allEntities, uuidFieldMap: uuidFieldMap)
                var removed = 0
                var merged = 0

                // 3️⃣ Deduplica per gruppo
                for (_, entities) in grouped where entities.count > 1 {
                    var preferred = entities.first!
                    for dup in entities.dropFirst() {
                        let chosen = discriminator.choosePreferred(preferred, dup)
                        if chosen === preferred {
                            merge(from: dup, into: preferred)
                            dup.delete()
                            removed += 1
                        } else {
                            merge(from: preferred, into: dup)
                            preferred.delete()
                            preferred = dup
                            removed += 1
                        }
                        merged += 1
                    }
                }

                try context.save()
                print("[GraphDedupEngine] ✅ Dedup completata — merged: \(merged), rimossi: \(removed)")

            } catch {
                print("[GraphDedupEngine] ❌ Errore durante la deduplicazione: \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Raggruppa le Entity per UUID logico (usando `uuidFieldMap`).
    private static func groupEntitiesByUUID(
        _ entities: [Entity],
        uuidFieldMap: [String: String]
    ) -> [String: [Entity]] {
        var dict = [String: [Entity]]()
        for entity in entities {
            if let uuid = uuidValue(for: entity, using: uuidFieldMap) {
                dict[uuid, default: []].append(entity)
            }
        }
        return dict
    }

    /// Copia proprietà, tag, gruppi e relazioni (shallow merge).
    private static func merge(from source: Entity, into target: Entity) {
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

        // Ricrea relazioni come soggetto
        for rel in source.relationshipsWhenSubject {
            guard let object = rel.object else { continue }
            if !target.relationshipsWhenSubject.contains(where: {
                $0.type == rel.type && $0.object === object
            }) {
                let newRel = target.is(relationship: rel.type)
                newRel.object = object
            }
        }

        // Ricrea relazioni come oggetto
        for rel in source.relationshipsWhenObject {
            guard let subject = rel.subject else { continue }
            if !target.relationshipsWhenObject.contains(where: {
                $0.type == rel.type && $0.subject === subject
            }) {
                let newRel = subject.is(relationship: rel.type)
                newRel.object = target
            }
        }

        // Ricrea azioni dove source è soggetto
        for action in source.actionsWhenSubject {
            if !target.actionsWhenSubject.contains(where: { $0.type == action.type }) {
                let newAction = target.will(action: action.type)
                for obj in action.objects { newAction.add(objects: obj) }
            }
        }

        // Ricrea azioni dove source è oggetto
        for action in source.actionsWhenObject {
            if !target.actionsWhenObject.contains(where: { $0.type == action.type }) {
                let newAction = action.subjects.first?.will(action: action.type)
                newAction?.add(objects: target)
            }
        }
    }

    /// Estrae l’UUID logico dal payload.
    private static func uuidValue(for entity: Entity, using uuidFieldMap: [String: String]) -> String? {
        guard let field = uuidFieldMap[entity.type],
              let value = entity[dynamicMember: field] as? String else {
            return nil
        }
        return value
    }
}
