//
//  GraphArchiver.swift
//  GraphCK
//
//  Created by Valerio Buriani on 18/09/25.
//


import Foundation
import UIKit
import PDFKit

/// Serializza oggetti legacy (usati nel vecchio campo `object`) in modo sicuro.
/// Garantisce compatibilità con `GraphValueTransformer`.
enum GraphArchiver {
    
    /// Serializza un oggetto compatibile in `Data`.
    /// - Throws: se il tipo non è archiviabile.
    static func archive(_ object: Any) throws -> Data {
        let archivable: Any

        switch object {
        case let s as NSString:
            archivable = String(s)
        case let n as NSNumber:
            archivable = n
        case let d as NSDate:
            archivable = Date(timeIntervalSinceReferenceDate: d.timeIntervalSinceReferenceDate)
        case let url as NSURL:
            archivable = URL(string: url.absoluteString ?? "") ?? ""
        case let img as UIImage:
            guard img.size != .zero else {
                 throw NSError(domain: "GraphArchiver", code: 100, userInfo: [
                    NSLocalizedDescriptionKey: "UIImage ha dimensione zero e viene ignorata"
                ])
            }

            guard let png = img.pngData() else {
                throw NSError(domain: "GraphArchiver", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to convert UIImage to PNG"
                ])
            }

            archivable = png
        case let pdf as PDFDocument:
            guard let data = pdf.dataRepresentation() else {
                throw NSError(domain: "GraphArchiver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to extract PDF data"])
            }
            archivable = data
        case let data as Data:
            archivable = data
        case let codable as NSSecureCoding:
            archivable = codable
        default:
            // Fallback con log
            let typeName = String(describing: type(of: object))
            throw NSError(domain: "GraphArchiver", code: 99, userInfo: [NSLocalizedDescriptionKey: "Unsupported type for archiving: \(typeName)"])
        }

        return try NSKeyedArchiver.archivedData(withRootObject: archivable, requiringSecureCoding: true)
    }
}
