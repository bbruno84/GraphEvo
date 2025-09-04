/*
 * The MIT License (MIT)
 *
 * Copyright (C) 2019, CosmicMind, Inc. <http://cosmicmind.com>.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import CoreData

/**
 Cloud stroage transition types for when changes happen
 to the iCloud account directly.
 */
@objc(GraphCloudStorageTransition)
public enum GraphCloudStorageTransition: UInt {
  case accountAdded
  case accountRemoved
  case contentRemoved
  case initialImportCompleted
  case unknown
  
  init(type : UInt) {
    switch type {
    case 1:
      self = .accountAdded
    case 2:
      self = .accountRemoved
    case 3:
      self = .contentRemoved
    case 4:
      self = .initialImportCompleted
    default:
      self = .unknown
    }
  }
    
    var debugDescription : String {
        switch self {
        case .accountAdded:
            return "accountAdded"
        case .accountRemoved:
            return "accountRemoved"
        case .contentRemoved:
            return "contentRemoved"
        case .initialImportCompleted:
            return "initialImportCompleted"
        default:
            return "unknown"
        }
    }
}

internal struct Coordinator {
  /**
   Creates a NSPersistentStoreCoordinator.
   - Parameter name: Storage name.
   - Parameter type: Storage type.
   - Parameter location: Storage location.
   - Parameter options: Additional options.
   - Returns: An instance of NSPersistentStoreCoordinator.
   */
  static func create(type: String, location: URL, options: [NSObject: Any]? = nil) -> NSPersistentStoreCoordinator {
    var coordinator: NSPersistentStoreCoordinator?
    
    File.createDirectoryAtPath(location, withIntermediateDirectories: true, attributes: nil) { (success, error) in
      if let e = error {
        fatalError("[Graph Error: \(e.localizedDescription)]")
      }
      
      coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.create())
    }
    
    return coordinator!
  }
}

/// NSPersistentStoreCoordinator extension.
internal extension Graph {
  /**
   Adds the persistentStore to the persistentStoreCoordinator.
   - Parameter supported: A boolean indicating whether cloud
   storage is supported.
   */
    func addPersistentStore(supported: Bool) {
        guard let moc = managedObjectContext else {
            return
        }
        
        let options: [AnyHashable: Any]? = nil
    
    prepareSQLite()
    
    do {
      //try moc.persistentStoreCoordinator?.addPersistentStore(ofType: type, configurationName: nil, at: location, options: options)
        try moc.persistentStoreCoordinator?.addPersistentStore(type: .sqlite, at: location, options: options)
      
      location = moc.persistentStoreCoordinator!.persistentStores.first!.url!
      
    } catch let e as NSError {
        
        NotificationCenter.default.post(name: Notification.Name(rawValue: "showErrorPopup" ),
                                        object: nil,
                                        userInfo: ["error": e.localizedFailureReason ?? e.localizedDescription])
        
        //debugPrint("[Graph Error: \(e.localizedDescription)]")
        debugPrint("[Graph Error: \(e.localizedFailureReason ?? e.localizedDescription)]")
//      fatalError("[Graph Error: \(e.localizedDescription)]")
    }
  }
  
}
