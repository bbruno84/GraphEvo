//
//  BaselineDedupDiscriminator.swift
//  GraphCK
//
//  General-purpose discriminator for MigrationV1 baseline merge.
//  Rules for all entities:
//  1) entity with more relationships wins
//  2) entity from the more populated DB wins (total entities count)
//  3) final tie-breaker: baseline wins (configurable)
//

import Foundation

struct BaselineDedupDiscriminator: DedupDiscriminator {
    enum Origin { case local, baseline }

    private let localEntityCount: Int
    private let baselineEntityCount: Int
    private let originOf: (Entity) -> Origin
    private let preferBaselineOnTie: Bool

    /// Initialize with DB population hints and an origin resolver.
    /// - Parameters:
    ///   - localEntityCount: total number of entities in the local store
    ///   - baselineEntityCount: total number of entities in the baseline store
    ///   - originOf: closure that returns `.local` or `.baseline` for a given entity
    ///   - preferBaselineOnTie: final tie breaker (default: true)
    init(
        localEntityCount: Int,
        baselineEntityCount: Int,
        originOf: @escaping (Entity) -> Origin,
        preferBaselineOnTie: Bool = true
    ) {
        self.localEntityCount = localEntityCount
        self.baselineEntityCount = baselineEntityCount
        self.originOf = originOf
        self.preferBaselineOnTie = preferBaselineOnTie
    }

    // MARK: - DedupDiscriminator

    func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity {
        // 1) More relationships wins
        let lhsRel = totalRelationships(lhs)
        let rhsRel = totalRelationships(rhs)
        if lhsRel != rhsRel { return (lhsRel > rhsRel) ? lhs : rhs }

        // 2) Database population wins
        if localEntityCount != baselineEntityCount {
            let lhsOrigin = originOf(lhs)
            let rhsOrigin = originOf(rhs)
            if localEntityCount > baselineEntityCount {
                if lhsOrigin == .local { return lhs }
                if rhsOrigin == .local { return rhs }
            } else {
                if lhsOrigin == .baseline { return lhs }
                if rhsOrigin == .baseline { return rhs }
            }
        }

        // 3) Final tie-breaker: baseline wins
        return prefersBaselineBetween(lhs, rhs)
    }

    // MARK: - Helpers

    private func prefersBaselineBetween(_ a: Entity, _ b: Entity) -> Entity {
        if preferBaselineOnTie {
            return originOf(a) == .baseline ? a : b
        } else {
            return originOf(a) == .local ? a : b
        }
    }

    private func totalRelationships(_ e: Entity) -> Int {
        // Replace with Graph API: count all relationships for entity
        // Example: e.allRelationships().count
        return e.relationships.count
    }
}
