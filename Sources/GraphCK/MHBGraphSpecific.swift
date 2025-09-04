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
    
}

