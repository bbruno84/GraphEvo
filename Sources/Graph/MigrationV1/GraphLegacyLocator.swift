//
//  GraphLegacyLocator.swift
//  GraphCK
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation
import Graph

enum LegacyBase: String { case standard, appGroup }
enum LegacyRoute: String { case local, cloud }

struct LegacyStoreInfo {
    let url: URL
    let base: LegacyBase
    let route: LegacyRoute
    let sizeBytes: Int64
    let mtime: Date
    let wal: URL?
    let shm: URL?
    let walSize: Int64?
    let shmSize: Int64?
    let walMtime: Date?
    let shmMtime: Date?
}

enum GraphLegacyLocator {
    struct Score { let score: Double; let reason: String }

    /// Sceglie il miglior candidato con ranking elastico.
    /// - Parameters:
    ///   - name: nome Graph (sottocartella in Local/Cloud)
    ///   - preferred: URL preferito (può essere il file Graph.sqlite **o** la cartella Local/<name> / Cloud/<name>)
    ///   - preferredBonus: bonus additivo se combacia (0.0–0.5 tipicamente)
    ///   - forcePreferredIfReasonable: se true, il preferred vince se supera soglie minime
    static func chooseBestLegacyStore(
        name: String,
        appGroupID: String? = "group.MyHomeBills",
        preferred: URL? = nil,
        preferredBonus: Double = 0.25,
        forcePreferredIfReasonable: Bool = true,
        minPreferredSizeBytes: Int64 = 128_000,   // ~125 KB
        maxPreferredAgeDays: Double = 365,
        now: Date = Date(),
        printDebug: Bool = true
    ) throws -> (best: LegacyStoreInfo?, all: [LegacyStoreInfo]) {

        let all = try findCandidateStores(name: name, appGroupID: appGroupID)

        // Se richiesto, prova a forzare il preferred se "ragionevole"
        if forcePreferredIfReasonable, let p = preferred,
           let pInfo = all.first(where: { matchesPreferred(info: $0, preferred: p) }) {

            let ageDays = max(0, now.timeIntervalSince(pInfo.mtime)) / (60*60*24)
            if pInfo.sizeBytes >= minPreferredSizeBytes, ageDays <= maxPreferredAgeDays {
                if printDebug {
                    print("✅ Forcing preferred store:", pInfo.url.path,
                          "(size \(pInfo.sizeBytes) bytes, age ~\(Int(ageDays))d)")
                }
                return (pInfo, all)
            } else if printDebug {
                print("ℹ️ Preferred found ma non forzato (size=\(pInfo.sizeBytes) bytes, ageDays~\(Int(ageDays)))")
            }
        }

        let ranked = rankStores(all, preferred: preferred, preferredBonus: preferredBonus, now: now)

        if printDebug {
            print("— Legacy candidates ranking —")
            for (i, tup) in ranked.enumerated() {
                let info = tup.0, s = tup.1
                print(String(format: "%2d) %.2f  %@  base=%@ route=%@  size=%.1f MB  mtime=%@  %@",
                             i+1, s.score, info.url.path, info.base.rawValue, info.route.rawValue,
                             Double(info.sizeBytes)/1_048_576.0,
                             DateFormatter.localizedString(from: info.mtime, dateStyle: .short, timeStyle: .short),
                             s.reason))
            }
        }

        return (ranked.first?.0, all)
    }

    static func weightStore(_ info: LegacyStoreInfo, now: Date, preferred: URL?, preferredBonus: Double) -> Score {
        // Recency (half-life 60 giorni)
        let ageDays = max(0, now.timeIntervalSince(info.mtime)) / (60*60*24)
        let recency = exp(-ageDays / 60.0)

        // Size: log-normalized su [200KB, 300MB] (empty Graph baseline ≈192 KB)
        let s = max(1.0, Double(info.sizeBytes))
        let minB: Double = 200_000
        let maxB: Double = 300_000_000
        let sizeNorm: Double = {
            if s <= minB { return 0.0 }
            if s >= maxB { return 1.0 }
            let t = (log10(s) - log10(minB)) / (log10(maxB) - log10(minB))
            return max(0.0, min(1.0, t))
        }()

        // Bonus WAL/SHM recenti
        var journalBonus = 0.0
        if let walM = info.walMtime {
            let d = max(0, now.timeIntervalSince(walM)) / (60*60*24)
            journalBonus += (d < 7) ? 0.10 : 0.02
        }
        if let shmM = info.shmMtime {
            let d = max(0, now.timeIntervalSince(shmM)) / (60*60*24)
            journalBonus += (d < 7) ? 0.05 : 0.01
        }
        journalBonus = min(journalBonus, 0.15)

        // Bias leggeri
        let baseBias = (info.base == .appGroup) ? 0.10 : 0.05
        let routeBias = (info.route == .local) ? 0.07 : 0.03

        // Penalità
        let stalePenalty = (ageDays > 365) ? 0.25 : 0.0
        let tinyPenalty  = (s < 192_000) ? 0.30 : 0.0

        let wRecency = 0.55, wSize = 0.35, wExtras = 0.10
        var score = wRecency*recency + wSize*sizeNorm + wExtras*(journalBonus + baseBias + routeBias)
        score = max(0.0, score - stalePenalty - tinyPenalty)

        // Add preferred bonus if applicable
        let bonus = (preferred != nil && matchesPreferred(info: info, preferred: preferred!)) ? preferredBonus : 0.0
        let totalScore = max(0.0, score + bonus)
        let reason = String(format: "[recency=%.2f size=%.2f] +extras(%.2f) -pen(%.2f)%@ (open scale)",
                            recency, sizeNorm, (journalBonus + baseBias + routeBias),
                            (stalePenalty + tinyPenalty),
                            bonus > 0 ? String(format: " +preferred(%.2f)", bonus) : "")
        return Score(score: totalScore, reason: reason)
    }

    static func rankStores(_ stores: [LegacyStoreInfo], preferred: URL?, preferredBonus: Double, now: Date) -> [(LegacyStoreInfo, Score)] {
        return stores
            .map { info in (info, weightStore(info, now: now, preferred: preferred, preferredBonus: preferredBonus)) }
            .sorted { $0.1.score > $1.1.score }
    }

    static func findCandidateStores(name: String, appGroupID: String? = "group.MyHomeBills") throws -> [LegacyStoreInfo] {
        var bases: [(LegacyBase, URL)] = []

        if let std = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CosmicMind/Graph") {
            bases.append((.standard, std))
        }
        if let id = appGroupID,
           let grp = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent("CosmicMind/Graph") {
            bases.append((.appGroup, grp))
        }

        var results: [LegacyStoreInfo] = []
        for (baseKind, root) in bases {
            for routeKind in [LegacyRoute.local, .cloud] {
                let dir = root.appendingPathComponent("\(routeKind == .local ? "Local" : "Cloud")/\(name)")
                let sqlite = dir.appendingPathComponent("Graph.sqlite")
                guard FileManager.default.fileExists(atPath: sqlite.path) else { continue }

                let wal = dir.appendingPathComponent("Graph.sqlite-wal")
                let shm = dir.appendingPathComponent("Graph.sqlite-shm")

                let attrs: [FileAttributeKey: Any]
                do {
                    attrs = try FileManager.default.attributesOfItem(atPath: sqlite.path)
                } catch {
                    // If attributes cannot be read, propagate error
                    throw error
                }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast

                var walSize: Int64?; var walM: Date?
                var shmSize: Int64?; var shmM: Date?

                if FileManager.default.fileExists(atPath: wal.path) {
                    let a: [FileAttributeKey: Any]
                    do {
                        a = try FileManager.default.attributesOfItem(atPath: wal.path)
                    } catch {
                        throw error
                    }
                    walSize = (a[.size] as? NSNumber)?.int64Value
                    walM = (a[.modificationDate] as? Date)
                }
                if FileManager.default.fileExists(atPath: shm.path) {
                    let a: [FileAttributeKey: Any]
                    do {
                        a = try FileManager.default.attributesOfItem(atPath: shm.path)
                    } catch {
                        throw error
                    }
                    shmSize = (a[.size] as? NSNumber)?.int64Value
                    shmM = (a[.modificationDate] as? Date)
                }

                results.append(LegacyStoreInfo(
                    url: sqlite, base: baseKind, route: routeKind,
                    sizeBytes: size, mtime: mtime,
                    wal: FileManager.default.fileExists(atPath: wal.path) ? wal : nil,
                    shm: FileManager.default.fileExists(atPath: shm.path) ? shm : nil,
                    walSize: walSize, shmSize: shmSize,
                    walMtime: walM, shmMtime: shmM
                ))
            }
        }
        return results
    }

    // MARK: - Preferred matching
    private static func matchesPreferred(info: LegacyStoreInfo, preferred: URL) -> Bool {
        let p = preferred.standardizedFileURL
        let isDir = (try? preferred.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        if isDir {
            // se è la cartella Local/<name> o Cloud/<name>, confronta la parent di Graph.sqlite
            return info.url.deletingLastPathComponent().standardizedFileURL == p
        } else {
            // se è un file, confronta direttamente
            return info.url.standardizedFileURL == p
        }
    }
}
