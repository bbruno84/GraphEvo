//
//  GraphProvider.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import Foundation
import GraphCK

final class GraphProvider {
    
    static let shared = GraphProvider()
    private(set) var graph: Graph

    private init() {
        // Imposta il container CloudKit (modifica il valore se necessario)
        Graph.cloudKitContainerIdentifier = "iCloud.com.valerioburiani.GraphCKDemo"
        
        // Istanzia Graph (sincronizzato)
        graph = Graph(name: "Main")
    }

    func configure() {
        // Non più necessario fare nulla qui
    }
}
