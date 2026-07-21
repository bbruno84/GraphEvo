//
//  GraphRemoteChangeCoordinator.swift
//  GraphCK
//
//  Serializes and coalesces Persistent History remote-change processing.
//

import Foundation

internal final class RemoteChangeCoordinator {
    private weak var graph: Graph?
    private let queue: DispatchQueue
    private var pending = false
    private var processing = false

    init(graph: Graph) {
        self.graph = graph
        self.queue = DispatchQueue(label: "GraphCK.RemoteChangeCoordinator.\(graph.route)")
    }

    func enqueue() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = true
            self.startIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard !processing, pending, let graph else { return }
        processing = true
        pending = false

        graph.processPersistentHistoryBatch { [weak self] processed in
            guard let self else { return }
            self.queue.async {
                self.processing = false
                if processed {
                    self.pending = true
                }
                self.startIfNeeded()
            }
        }
    }
}
