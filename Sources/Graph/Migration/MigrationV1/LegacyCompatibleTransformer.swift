//
//  LegacyCompatibleTransformer.swift
//  GraphCK
//
//  Created by Valerio Buriani on 17/09/25.
//
import Foundation
import UIKit
import CoreData

@objc(LegacyCompatibleTransformer)
final class LegacyCompatibleTransformer: ValueTransformer {
    override class func transformedValueClass() -> AnyClass { NSData.self }
    override class func allowsReverseTransformation() -> Bool { true }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let archived = value as? Data else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClasses: [
                NSString.self, NSNumber.self, NSDate.self,
                NSData.self, NSNull.self, NSArray.self, NSDictionary.self
            ], from: archived)
        } catch {
            print("🚨 Failed to unarchive legacy object: \(error)")
            return nil
        }
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        } catch {
            print("🚨 Failed to rearchive legacy object: \(error)")
            return nil
        }
    }

    static func registerTemporarilyForMigration() {
        let transformer = LegacyCompatibleTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: NSValueTransformerName("GraphValueTransformer"))
        print("🧩 [Migration] LegacyCompatibleTransformer registered as GraphValueTransformer")
    }
}


