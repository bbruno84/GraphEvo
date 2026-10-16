//
//  GraphCloudStorageTransition.swift
//  GraphEvo
//
//  Compatibility type for the deprecated ubiquitous-store delegate API.
//  The modern GraphEvo stack uses NSPersistentCloudKitContainer instead.
//

import Foundation

/// Cloud storage transition values retained for source compatibility with
/// the original Graph delegate API.
@objc(GraphCloudStorageTransition)
public enum GraphCloudStorageTransition: UInt {
    case accountAdded
    case accountRemoved
    case contentRemoved
    case initialImportCompleted
    case unknown

    init(type: UInt) {
        switch type {
        case 1: self = .accountAdded
        case 2: self = .accountRemoved
        case 3: self = .contentRemoved
        case 4: self = .initialImportCompleted
        default: self = .unknown
        }
    }

    var debugDescription: String {
        switch self {
        case .accountAdded: return "accountAdded"
        case .accountRemoved: return "accountRemoved"
        case .contentRemoved: return "contentRemoved"
        case .initialImportCompleted: return "initialImportCompleted"
        case .unknown: return "unknown"
        }
    }
}
