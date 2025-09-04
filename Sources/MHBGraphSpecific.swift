//
//  MHBGraphSpecific.swift
//  MyHomeBill
//
//  Created by Valerio Buriani on 07/02/2020.
//  Copyright © 2020 Marco Cavicchi. All rights reserved.
//

import Foundation
import CoreData

extension Graph {
    var tutteLeAbitazioni : [Entity?]{
        let search = Search<Entity>(graph: self).where(.type("Abitazioni"))
        return search.sync(completion: nil)
    }
    
    var tutteLeCategorie : [Entity?] {
        let search = Search<Entity>(graph: self).where(.type("Categoria"))
        return search.sync(completion: nil)
    }
    
    var tutteLeCategorieCustom : [Entity?] {
        let search = Search<Entity>(graph: self).where(.type("AttributiCustom"))
        return search.sync(completion: nil)
    }
    
    var tutteLeBollette : [Entity] {
        let search = Search<Entity>(graph: self).where(.type("Bolletta"))
        return search.sync(completion: nil)
    }
    
    var conteggiAbitazione : [Entity] {
        let search = Search<Entity>(graph: self).where(.type("Conteggi_abitazione"))
        return search.sync(completion: nil)
    }
    
    var multimediaBollette : [Entity] {
        let search = Search<Entity>(graph: self).where(.type("MediaBollette"))
        return search.sync(completion: nil)
    }
    
    var immaginiBollette : [Entity] {
        let search = Search<Entity>(graph: self).where(.type("MediaBollette") && "media_type" == "img")
        return search.sync(completion: nil)
    }
    
    var pdfBollette : [Entity] {
        let search = Search<Entity>(graph: self).where(.type("MediaBollette") && "media_type" == "pdf")
        return search.sync(completion: nil)
    }
    
    var regoleRicorrenze : [Entity] {
        let search = Search<Entity>(graph: self).where(.type("RecurrenciesRule"))
        return search.sync(completion: nil)
    }

    
    var relazioniCAT : [Relationship] {
        
        let search = Search<Relationship>(graph: self).where(.type("Relazioni_bolletta_categoria"))
        let relazioni = search.sync(completion: nil)
        return relazioni
    }
    
    var relazioniIMG : [Relationship?] {
        
        let search = Search<Relationship>(graph: self).where(.type("Relazioni_bolletta_immagini"))
        let relazioni = search.sync(completion: nil)
        return relazioni
    }
    
    var relazioniCONTI : [Relationship?] {
        
        let search = Search<Relationship>(graph: self).where(.type("Relazioni_categoria_conti"))
        let relazioni = search.sync(completion: nil)
        return relazioni
    }
    
    var relazioniCUSTOM : [Relationship?] {
        
        let search = Search<Relationship>(graph: self).where(.type("Relazioni_categorieCustom"))
        let relazioni = search.sync(completion: nil)
        return relazioni
    }
    
    var relazioniRicorrenzeBollette : [Relationship] {
        
        let search = Search<Relationship>(graph: self).where(.type("Relazioni_bolletta_regoleRicorrenze"))
        let relazioni = search.sync(completion: nil)
        return relazioni
    }
    
    var relazioniRicorrenzeCategorie : [Relationship] {
        
        let search = Search<Relationship>(graph: self).where(.type("Relazioni_regoleRicorrenze_categoria"))
        let relazioni = search.sync(completion: nil)
        return relazioni
    }
    
    
    //    var relazioniABITAZIONE : [Relationship] {
    //        let search = Search<Relationship>(graph: db).where(.type("Relazioni_categoria_abitazione"))
    //        let relazioni = search.sync(completion: nil)
    //        return relazioni
    //
    //    }
    
    //    var relazioniABITAZIONECONTI : [Relationship] {
    //        let search = Search<Relationship>(graph: db).where(.type("Relazioni_abitazione_conti"))
    //        let relazioni = search.sync(completion: nil)
    //        return relazioni
    //
    //    }
    
    var psc : NSPersistentStoreCoordinator? {
        return self.managedObjectContext.persistentStoreCoordinator
    }
    
    var pS: NSPersistentStore? {
        guard self.psc != nil else {return nil}
        guard let firstStore = psc?.persistentStores.first?.url else {return nil}
        let store = psc!.persistentStore(for: firstStore)
        return store
    }
    
    var storedURL : URL? {
        self.pS?.url
    }
    
    static func setupStoreOptions(appID : String? = nil, appName: String? = nil, removeUbiquity : Bool = false, rebuildFromCloud : Bool = false) -> [AnyHashable : Any] {
        var options = [AnyHashable : Any]()
        
        if let appID_ = appID {
            options[NSPersistentStoreUbiquitousPeerTokenOption] = appID_
        }
        
        if let appName_ = appName {
            options[NSPersistentStoreUbiquitousContentNameKey] = appName_
        }
        
        if removeUbiquity == true {
            options[NSPersistentStoreRemoveUbiquitousMetadataOption] = 1
        }
        
        if rebuildFromCloud == true {
            options[NSPersistentStoreRebuildFromUbiquitousContentOption] = 1
        }
        
        return options
    }
    
//    func changeStore(cloud: Bool = false,store: GraphStoreDescription.graphCloudIdentifiers?, completion: @escaping (Bool, Error?)->()) {
//        guard let coordinator = self.psc else {sbLog.error("No Persistent Store Coordinator"); return}
//        guard let persistentStore = self.pS else {sbLog.error("No Persistent Store"); return}
//        guard let url = persistentStore.url else {return}
//
//        var done : Bool = false
//        var error_ : Error?
//
//        var cloudOptions : [AnyHashable : Any]?
//
//        if cloud == true {
//            cloudOptions = [AnyHashable : Any]()
//            cloudOptions?[NSPersistentStoreUbiquitousContentNameKey] = "MyHomeBillsCloud"
//            cloudOptions?[NSPersistentStoreUbiquitousPeerTokenOption] = {
//                switch store {
//                case .application:return "application"
//                case .none: return nil
//                default:
//                    return store?.rawValue
//                }
//            }()
//        }
//
//        do {
//            try coordinator.remove(persistentStore)
//            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: cloudOptions)
//        } catch {
//            error_ = error
//            completion(done,error)
//            debugPrint("[Graph: change store] \(error.localizedDescription)")
//            return
//        }
//
//        done = true
//        completion(done,error_)
//
//    }
    
//    func moveTo(destination: GraphStoreDescription.locations, cloud: Bool, cloudOptions : [AnyHashable: Any]? = nil, completion: @escaping(Bool,Error?)->()){
//        
//        
//        var newStore : NSPersistentStore?
//        var destinationFolder : URL
//        var options : [AnyHashable: Any]?
//        var sourceOptions : [AnyHashable: Any] = [NSPersistentStoreRemoveUbiquitousMetadataOption : 1]
//        let routing : String
//        guard let pSC = self.psc else {completion(false, GenericError(message: "[Graph: moveTo] No Persistent Store Coordinator")) ; return}
//        guard let oldStore = self.pS else {completion(false, GenericError(message: "[Graph: moveTo] No Persistent Store")) ; return}
//        
////        self.delegate = nil
//        
//        if cloud == true{
//            routing = "Cloud/MyHomeBillsCloud/"
//            if cloudOptions != nil {
//                options = cloudOptions
//            } else {
//                options = [AnyHashable : Any]()
//            }
//            options?[NSPersistentStoreUbiquitousContentNameKey] = "MyHomeBillsCloud"
//            
//        } else {
//            routing = "Local/MyHomeBillsLocal/"
//        }
//
//        switch destination {
//        case .appGroup:
//            destinationFolder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.MyHomeBills")!.appendingPathComponent("CosmicMind/Graph/\(routing)/")
//        case .standard:
//            destinationFolder = File.path(.applicationSupportDirectory, path: "CosmicMind/Graph/\(routing)/")!
//        }
//        
//        let destinationURL = destinationFolder.appendingPathComponent("Graph.sqlite")
//        
//        
//        sbLog.info("Starting Graph migration to: \(destination)")
//        
//        File.createDirectoryAtPath(destinationFolder, withIntermediateDirectories: true, attributes: nil) { (done, error) in
//            if done {
//                
//                do{
//                    try pSC.replacePersistentStore(at: pSC.persistentStores.first!.url!,
//                                                   destinationOptions: options,
//                                                   withPersistentStoreFrom: pSC.persistentStores.first!.url!,
//                                                   sourceOptions: sourceOptions,
//                                                   ofType: NSSQLiteStoreType)
//                }catch{
//                    completion(false, error)
//                    return
//                }
//            
//            }
//            if let errore = error {
//                completion(false, errore)
//                return
//            }
//        }
//        
//        sbLog.info("Migration successfull")
//        completion(true,nil)
//
//    }
    
}


@objc(DefaultTransformer)
class DefaultTransformer: ValueTransformer {
   override class func transformedValueClass() -> AnyClass {
       return NSData.self
   }

   override open func reverseTransformedValue(_ value: Any?) -> Any? {
       guard let value = value as? Data else {
           return nil
       }
       return NSKeyedUnarchiver.unarchiveObject(with: value)
   }

   override class func allowsReverseTransformation() -> Bool {
       return true
   }

   override func transformedValue(_ value: Any?) -> Any? {
       guard let value = value else {
           return nil
       }
       return NSKeyedArchiver.archivedData(withRootObject: value)
   }
}
