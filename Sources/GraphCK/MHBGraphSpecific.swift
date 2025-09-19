//
//  MHBGraphSpecific.swift
//  MyHomeBill
//
//  Created by Valerio Buriani on 07/02/2020.
//  Copyright © 2020 Marco Cavicchi. All rights reserved.
//

import Foundation
import CoreData
import UIKit
import PDFKit

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
    
    static let uuidFieldMap: [String: String] = ["Bolletta" : "codice_bolletta",
                                                 "MediaBollette" : "codice_multimediaBolletta",
                                                 "Conteggi" : "codice_anno",
                                                 "Categoria" : "codice_categoria",
                                                 "Conteggi_abitazione" : "codice_anno",
                                                 "RecurrenciesRule" : "codice_regola",
                                                 "AttributiCustom" : "AttributiCustom"]
    
    
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
    
    func dbdump() {
        let allEntities = Search<Entity>(graph: self).where(.type("*")).sync()
        print("🔎 Entity count: \(allEntities.count)")

        var expectedPDF = 0
        var expectedImage = 0
        var PDFcount = 0
        var imageCount = 0
        var dataCount = 0
        var otherCount = 0
        var categorieCount = 0
        var categorieCustom = 0
        
        var entityTypeCounts: [String: Int] = [:]
        
        for entitiy in allEntities {
            entityTypeCounts[entitiy.type, default: 0] += 1
        }
        
        print("📊 Entities trovate:")
        for (type, count) in entityTypeCounts.sorted(by: { $0.value > $1.value }) {
            print("   • \(type): \(count)")
            switch type {
                case "MediaBollette":
                let mediaEntities = Search<Entity>(graph: self).where(.type("MediaBollette")).sync()
                for entity in mediaEntities {
                    if entity[dynamicMember: "media_type"] as? String == "pdf" {
                        expectedPDF += 1
                    } else if entity[dynamicMember: "media_type"] as? String == "img" {
                        expectedImage += 1
                    }
                    if let value = entity[dynamicMember: "media"] {
                        if value is UIImage {
                            
                            imageCount += 1
                        } else if let data = value as? Data {
                            if PDFDocument(data: data) != nil {
                                PDFcount += 1
                                //saveDocumentToDisk(document, named: UUID().uuidString)
                            } else if UIImage(data: data) != nil {
                                imageCount += 1
                            } else {
                                dataCount += 1
                            }
                        } else {
                            otherCount += 1
                        }
                    }
                }
                print("     • Expected images: \(expectedImage)")
                print("     • 🖼️ UIImage: \(imageCount)")
                print("     • Expected PDFs: \(expectedPDF)")
                print("     • 📄 PDFDocument: \(PDFcount)")
            case "Categoria":
                let categorie = Search<Entity>(graph: self).where(.type("Categoria")).sync()
                for categoria in categorie {
                    if categoria[dynamicMember: "tipo"] as? String == "custom" {
                        categorieCustom += 1
                    } else {
                        categorieCount += 1
                    }
                }
                print("     • di cui custom: \(categorieCustom)")
            default:
                continue
            }
        }
    }
    
}


