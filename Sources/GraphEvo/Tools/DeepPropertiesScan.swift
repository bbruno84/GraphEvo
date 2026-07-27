//
//  DeepPropertiesScan.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation
import CoreData

extension GraphTools {
    /// Deep scan of all transformable `object` payloads in all property entities, reporting which fail to unarchive.
    /// Prints a breakdown summary and sample offenders, similar to debugScanUnarchivingIssues.
    public static func deepScanUnarchivingIssues(context: NSManagedObjectContext, sampleLimit: Int = 2000) {
        let entityNames = ["ManagedEntityProperty", "ManagedActionProperty", "ManagedRelationshipProperty"]

        var total = 0
        var ok = 0
        var failures = 0
        var nestedDataCount = 0
        var rawOk = 0
        var failuresByProperty: [String: Int] = [:]
        var dataKindCounters: [String: Int] = [:]
        var samplePrinted = 0

        var nilCount = 0
        var typeCounters: [String: Int] = [:]
        for entityName in entityNames {
            let req = NSFetchRequest<NSManagedObject>(entityName: entityName)
            // Remove predicate: req.predicate = NSPredicate(format: "object != nil")
            req.fetchLimit = sampleLimit
            do {
                let rows = try context.fetch(req)
                for row in rows {
                    total += 1
                    let propName = (row.value(forKey: "name") as? String) ?? "<no-name>"
                    let payload = row.primitiveValue(forKey: "object") ?? row.value(forKey: "object")
                    if payload == nil {
                        print("[DeepScan] ⚠️ property '\(propName)' in \(entityName) has nil payload")
                        // Caso 1: nil
                        nilCount += 1
                    } else if let dataPayload = payload as? Data {
                        // Caso 2: Data
                        if let decoded = GraphValueTransformer().reverseTransformedValue(dataPayload) {
                            ok += 1
                            typeCounters[String(describing: type(of: decoded)), default: 0] += 1
                            if decoded is Data { nestedDataCount += 1 }
                        } else {
                            let kind = Self.dataKind(for: dataPayload)
                            if kind.hasPrefix("PDF (raw)") || kind.hasPrefix("PNG (raw)") || kind.hasPrefix("JPEG (raw)") {
                                rawOk += 1
                                dataKindCounters[kind, default: 0] += 1
                                if samplePrinted < sampleLimit {
                                    print("[DeepScan] ℹ️ Raw recognized kind=\(kind) \(entityName).\(propName) bytes=\(dataPayload.count)")
                                    samplePrinted += 1
                                }
                            } else {
                                failures += 1
                                failuresByProperty[propName, default: 0] += 1
                                dataKindCounters[kind, default: 0] += 1
                                if samplePrinted < sampleLimit {
                                    print("[DeepScan] ❌ \(entityName).\(propName) bytes=\(dataPayload.count) kind=\(kind)")
                                    samplePrinted += 1
                                }
                            }
                        }
                    } else {
                        // Caso 3: Non-Data non-nil
                        ok += 1
                        let typeName = String(describing: type(of: payload!))
                        typeCounters[typeName, default: 0] += 1
                    }
                }
            } catch {
                print("[DeepScan] ERROR: fetch \(entityName) failed: \(error)")
            }
        }

        print("📊 [DeepScan] total=\(total) ok=\(ok) failures=\(failures) nestedData=\(nestedDataCount) rawOk=\(rawOk) nil=\(nilCount)")
        let checkSum = ok + failures + rawOk + nilCount
        print("📊 [DeepScan] Consistency check: ok+failures+rawOk+nil=\(checkSum) vs total=\(total) \(checkSum == total ? "✅" : "❌")")
        if !failuresByProperty.isEmpty {
            print("📊 [DeepScan] Failures by property name (desc):")
            for (k, v) in failuresByProperty.sorted(by: { $0.value > $1.value }) {
                print("   • \(k): \(v)")
            }
        }
        if !dataKindCounters.isEmpty {
            print("📊 [DeepScan] Data kinds (desc):")
            for (k, v) in dataKindCounters.sorted(by: { $0.value > $1.value }) {
                print("   • \(k): \(v)")
            }
        }
        if !typeCounters.isEmpty {
            print("📊 [DeepScan] Non-Data payload types (desc):")
            for (typeName, count) in typeCounters.sorted(by: { $0.value > $1.value }) {
                print("   • \(typeName): \(count)")
            }
        }
    }
}
