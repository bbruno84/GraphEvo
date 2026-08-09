//
//  GraphLegacyContracts.swift
//  GraphEvo
//
//  Deprecated delegate and status contracts retained for source compatibility.
//

import Foundation

@objc(GraphDelegate)
public protocol GraphDelegate {
    @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
    @objc optional func graphWillPrepareCloudStorage(graph: Graph, transition: GraphCloudStorageTransition)

    @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
    @objc optional func graphDidPrepareCloudStorage(graph: Graph)

    @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
    @objc optional func graphWillUpdateFromCloudStorage(graph: Graph)

    @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
    @objc optional func graphDidUpdateFromCloudStorage(graph: Graph)
}

public enum GraphCloudStatus {
    case available
    case unavailable
}

public protocol GraphCloudStatusDelegate: AnyObject {
    /// Called when iCloud availability changes (or is first determined).
    func graph(_ graph: Graph, iCloudStatusChanged status: GraphCloudStatus)
}
