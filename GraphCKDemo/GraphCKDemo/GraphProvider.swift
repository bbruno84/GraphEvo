//
//  GraphProvider.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import Foundation
import Graph

final class GraphProvider {
    
    static let shared = GraphProvider()
    private(set) var graph: Graph

    private init() {
        // Imposta il container CloudKit (modifica il valore se necessario)
        Graph.cloudKitContainerIdentifier = "iCloud.com.valerioburiani.GraphCKDemo"
        
        // Istanzia Graph (sincronizzato)
        var configuration = GraphStoreConfiguration()
        configuration.name = "Main"
        configuration.cloudKitContainerIdentifier = Graph.cloudKitContainerIdentifier
        graph = Graph(configuration: configuration)
    }

    func configure() {
        // Non più necessario fare nulla qui
    }
}
