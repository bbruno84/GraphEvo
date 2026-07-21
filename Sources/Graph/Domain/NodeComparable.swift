//
//  NodeComparable.swift
//  GraphCK
//
//  Ordering semantics for Graph nodes.
//

import ObjectiveC

extension Node: Comparable {
    public static func == (left: Node, right: Node) -> Bool {
        left.id == right.id
    }

    public static func < (left: Node, right: Node) -> Bool {
        left.id < right.id
    }
}
