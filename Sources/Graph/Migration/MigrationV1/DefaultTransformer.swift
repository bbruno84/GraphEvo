//
//  DefaultTransformer.swift
//  GraphCK
//
//  Created by Valerio Buriani on 15/09/25.
//
import Foundation

@objc(DefaultTransformer)
class DefaultTransformer: ValueTransformer {
   override class func transformedValueClass() -> AnyClass {
       return NSData.self
   }

   @available(iOS, deprecated: 12.0, message: "Uses deprecated APIs intentionally for migration")
   override open func reverseTransformedValue(_ value: Any?) -> Any? {
       guard let value = value as? Data else {
           return nil
       }
       return NSKeyedUnarchiver.unarchiveObject(with: value)
   }

   override class func allowsReverseTransformation() -> Bool {
       return true
   }

   @available(iOS, deprecated: 12.0, message: "Uses deprecated APIs intentionally for migration")
   override func transformedValue(_ value: Any?) -> Any? {
       guard let value = value else {
           return nil
       }
       return NSKeyedArchiver.archivedData(withRootObject: value)
   }
}
