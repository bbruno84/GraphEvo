//
//  GraphValueTransformer.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//

import Foundation
import UIKit
import PDFKit

public enum GraphArchiverError: Error {
    case unsupported(String)
}

enum GraphAllowedClasses {
    static let list: [AnyClass] = [
        NSString.self,
        NSNumber.self,
        NSData.self,
        NSDate.self,
        NSNull.self,
        NSArray.self,
        NSDictionary.self,
        NSURL.self,
        UIImage.self,
        PDFDocument.self,
        AnyCodableObject.self,
        NSArrayOfAnyCodableObject.self,
        DictionaryOfAnyCodableObject.self
    ]
}

/// Serializza oggetti legacy (usati nel vecchio campo `object`) in modo sicuro.
/// Garantisce compatibilità con `GraphValueTransformer`.
public enum GraphArchiver {
    
    /// Serializza un oggetto compatibile in `Data`.
    /// - Throws: se il tipo non è archiviabile.
    public static func archive(_ object: Any) throws -> Data {
        let archivable: Any

        switch object {
        case let s as NSString:
            archivable = s
        case let n as NSNumber:
            archivable = n
        case let d as NSDate:
            archivable = d
        case _ as NSNull:
            archivable = NSNull()
        case let data as NSData:
            archivable = data
        case let arr as NSArray:
            archivable = arr
        case let dict as NSDictionary:
            archivable = dict
        case let pdf as PDFDocument:
            guard let data = pdf.dataRepresentation() else {
                throw GraphArchiverError.unsupported("PDFDocument without dataRepresentation")
            }
            return try NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)

        case let image as UIImage:
            guard let data = image.pngData() else {
                throw GraphArchiverError.unsupported("UIImage cannot be converted to PNG")
            }
            return try NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)

        case let codable as AnyCodableObject:
            archivable = codable

        case let codablearray as NSArrayOfAnyCodableObject:
            archivable = codablearray

        case let dict as DictionaryOfAnyCodableObject:
             archivable = dict
        case let url as NSURL:
            archivable = url
        default:
            // Fallback con log
            let typeName = String(describing: type(of: object))
            throw NSError(domain: "GraphArchiver", code: 99, userInfo: [NSLocalizedDescriptionKey: "Unsupported type for archiving: \(typeName)"])
        }

        return try NSKeyedArchiver.archivedData(withRootObject: archivable, requiringSecureCoding: true)
    }
    
    /// Deserializza un oggetto da Data usando la whitelist di classi consentite.
    /// - Throws: se il dato non può essere deserializzato oppure il tipo non è consentito.
    public static func unarchive(_ data: Data) throws -> Any {
        do {
            let classSet = NSSet(array: GraphAllowedClasses.list) as! Set<AnyHashable>
            let object = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classSet, from: data)
            return object as Any
        } catch {
            throw error
        }
    }
}


/// A secure value transformer used to archive and unarchive property values in Graph.
/// Ensures compatibility with `NSPersistentCloudKitContainer` by enforcing a strict class whitelist.
@objc(GraphValueTransformer)
public final class GraphValueTransformer: NSSecureUnarchiveFromDataTransformer {

    private static let registrationLock = NSLock()
    
    /// The name used to register the transformer.
    static let name = NSValueTransformerName("GraphValueTransformer")
    
    /// Class whitelist for secure decoding.
    public override class var allowedTopLevelClasses: [AnyClass] {
        
        return GraphAllowedClasses.list
    }
    
    public override func transformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else {
            return nil
        }

        do {
            let unarchived = try GraphArchiver.unarchive(data)

            if let anyCodable = unarchived as? AnyCodableObject {
                return anyCodable
            }
            if let arrAnyCodable = unarchived as? NSArrayOfAnyCodableObject {
                return arrAnyCodable
            }
            if let dictAnyCodable = unarchived as? DictionaryOfAnyCodableObject {
                return dictAnyCodable
            }

            return unarchived
        } catch {
            print("❌ [GraphValueTransformer] Errore durante l'unarchiviazione: \(error)")
            return nil
        }
    }
    
    public override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        
        do {
            return try GraphArchiver.archive(value)
        } catch {
            print("❌ [GraphValueTransformer] Errore durante l'archiviazione: \(error)")
            return nil
        }
    }
    
    /// Registers the transformer globally.
    public static func register() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        let transformer = GraphValueTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: GraphValueTransformer.name)
    }
}

/// A type-erased wrapper to allow encoding of arbitrary `Codable` values.
struct AnyCodableBox: Codable {
    private let value: Encodable

    init(_ value: Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Decoding AnyCodableBox is not supported")
        )
    }
}
