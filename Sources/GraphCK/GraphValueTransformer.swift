//
//  whitelist.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//


import Foundation

/// A secure value transformer used to archive and unarchive property values in Graph.
/// Ensures compatibility with `NSPersistentCloudKitContainer` by enforcing a strict class whitelist.
///
/// Supported types:
/// - `NSString`, `NSNumber`, `NSData`, `NSDate`, `NSNull`
/// - `NSArray`, `NSDictionary`
/// - `AnyCodableObject`, `NSArrayOfAnyCodableObject`, `DictionaryOfAnyCodableObject`
@objc(GraphValueTransformer)
final class GraphValueTransformer: NSSecureUnarchiveFromDataTransformer {
    
    /// The name used to register the transformer.
    static let name = NSValueTransformerName("GraphValueTransformer")
    
    /// Class whitelist for secure decoding.
    override class var allowedTopLevelClasses: [AnyClass] {
        return [
            NSString.self,
            NSNumber.self,
            NSData.self,
            NSDate.self,
            NSNull.self,
            NSArray.self,
            NSDictionary.self,
            AnyCodableObject.self,
            NSArrayOfAnyCodableObject.self,
            DictionaryOfAnyCodableObject.self
        ]
    }
    
    override func reverseTransformedValue(_ value: Any?) -> Any? {
            guard let data = value as? Data else {
                return nil
            }

            do {
                let classSet = NSSet(array: Self.allowedTopLevelClasses) as! Set<AnyHashable>
                let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classSet, from: data)
                return unarchived
            } catch {
                print("❌ [GraphValueTransformer] Errore durante l'unarchiviazione: \(error)")
                return nil
            }
        }
    
    /// Registers the transformer globally.
    static func register() {
        let transformer = GraphValueTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: GraphValueTransformer.name)
    }
}
