//
//  GraphProvider.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import Foundation
import GraphEvo

extension Notification.Name {
    static let graphProviderStateDidChange = Notification.Name("GraphCKDemo.graphProviderStateDidChange")
}

final class GraphProvider: NSObject, GraphCloudStatusDelegate {
    
    static let shared = GraphProvider()
    private(set) var graph: Graph
    private(set) var readiness: GraphReadiness
    private(set) var cloudStatus: GraphCloudStatus = .unavailable
    private(set) var lastError: GraphStoreOpeningError?

    private override init() {
        // Must match the container enabled in entitlements and the Developer
        // Portal. Xcode/account selects the CloudKit environment.
        Graph.cloudKitContainerIdentifier = "iCloud.com.valerioburiani.GraphCKDemo"

        var configuration = GraphStoreConfiguration()
        configuration.name = "Main"
        configuration.cloudKitContainerIdentifier = Graph.cloudKitContainerIdentifier
        graph = Graph(configuration: configuration)
        readiness = graph.readiness
        super.init()
        graph.cloudStatusDelegate = self
        graph.whenReady { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.readiness = .ready
                self.lastError = nil
                print("✅ GraphCKDemo graph ready: \(self.graph.location.path)")
            case .failure(let error):
                self.readiness = .failed(error)
                self.lastError = error
                print("❌ GraphCKDemo graph not ready: \(error.localizedDescription)")
            }
            self.publishStateChange()
        }
    }

    var isReady: Bool {
        if case .ready = readiness { return true }
        return false
    }

    func graphIfReady() -> Graph? {
        guard isReady else {
            print("⏳ GraphCKDemo: graph is not ready yet")
            return nil
        }
        return graph
    }

    func graph(_ graph: Graph, iCloudStatusChanged status: GraphCloudStatus) {
        cloudStatus = status
        let description = cloudStatusDescription()
        print("☁️ GraphCKDemo \(description)")
        publishStateChange()
    }

    func readinessDescription() -> String {
        switch readiness {
        case .initializing: return "Graph: opening"
        case .ready: return "Graph: ready"
        case .failed(let error): return "Graph: error — \(error.localizedDescription)"
        }
    }

    func cloudStatusDescription() -> String {
        switch cloudStatus {
        case .available: return "CloudKit: account available"
        case .unavailable: return "CloudKit: account unavailable"
        }
    }

    private func publishStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .graphProviderStateDidChange, object: self)
        }
    }
}
