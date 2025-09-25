//
//  uuidFieldMap.swift
//  MyHomeBill
//
//  Created by Valerio Buriani on 21/09/25.
//  Copyright © 2025 Marco Cavicchi. All rights reserved.
//
import Graph

extension Graph {
    static let uuidFieldMap: [String: String] = ["Bolletta" : "codice_bolletta",
                                                 "MediaBollette" : "codice_multimediaBolletta",
                                                 "Conteggi" : "codice_anno",
                                                 "Categoria" : "codice_categoria",
                                                 "Conteggi_abitazione" : "codice_anno",
                                                 "RecurrenciesRule" : "codice_regola",
                                                 "AttributiCustom" : "AttributiCustom"]
}
