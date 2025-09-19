//
//  MigrationV1Policies.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData
import UIKit
import PDFKit

/// Policy di migrazione per ManagedEntityProperty (campo object).
@objc(MigrationV1EntityPropertyPolicy)
public final class MigrationV1EntityPropertyPolicy: NSEntityMigrationPolicy {
    
    override init() {
        debugPrint("Migrating ManagedEntityProperty Class (V1)")
        super.init()
    }
    
    @objc func createCustomDestinationInstance(
        forSource sInstance: NSManagedObject,
        withName destName: String,
        in mapping: NSEntityMapping,
        manager: NSMigrationManager
    ) throws -> NSManagedObject {
        debugPrint("Creating custom destination instance")
        return NSManagedObject()
    }
    
    public override func createDestinationInstances(
        forSource sInstance: NSManagedObject,
        in mapping: NSEntityMapping,
        manager: NSMigrationManager
    ) throws {
        debugPrint("Creating destination instances")
        // For custom mapping types we create the destination instance manually
        guard let destName = mapping.destinationEntityName else { return }
        let dInstance = NSEntityDescription.insertNewObject(forEntityName: destName, into: manager.destinationContext)
        
        // Copy the "name" attribute
        var propertyName: String? = nil
        if let name = sInstance.value(forKey: "name") as? String {
            dInstance.setValue(name, forKey: "name")
            propertyName = name
        }
        
        // Read the legacy "object" value
        let legacyObject = sInstance.value(forKey: "object")
        
        var transformedValue: Any? = nil
        if let name = propertyName,
           let expectedTypes = MigrationV1TypeMapping.propertyTypes[name] {
            for expectedType in expectedTypes {
                if let casted = MigrationV1EntityPropertyPolicy.castLegacy(legacyObject, toExpected: expectedType) {
                    transformedValue = casted
                    break
                }
            }
        }
        // If not mapped or cast failed, fallback to universal casting
        if transformedValue == nil {
            transformedValue = MigrationV1EntityPropertyPolicy.castUniversal(legacyObject)
        }
        if let valueToSet = transformedValue {
            dInstance.setValue(valueToSet, forKey: "object")
        }
        
        manager.associate(sourceInstance: sInstance, withDestinationInstance: dInstance, for: mapping)
    }
}

private extension MigrationV1EntityPropertyPolicy {
    /// Attempts to cast legacy value to one of the expected types.
    static func castLegacy(_ value: Any?, toExpected expectedType: String) -> Any? {
        guard let value = value else { return nil }
        switch expectedType {
        case "String":
            if let str = value as? String {
                return str
            } else if let number = value as? NSNumber {
                return number.stringValue
            } else if let date = value as? Date {
                // ISO8601 string
                let isoFormatter = ISO8601DateFormatter()
                return isoFormatter.string(from: date)
            }
        case "Double":
            if let dbl = value as? Double {
                return dbl
            } else if let number = value as? NSNumber {
                return number.doubleValue
            } else if let str = value as? String, let dbl = Double(str) {
                return dbl
            }
        case "Int":
            if let intVal = value as? Int {
                return intVal
            } else if let number = value as? NSNumber {
                return number.intValue
            } else if let str = value as? String, let intVal = Int(str) {
                return intVal
            }
        case "Bool":
            if let boolVal = value as? Bool {
                return boolVal
            } else if let number = value as? NSNumber {
                return number.boolValue
            } else if let str = value as? String {
                let lower = str.lowercased()
                if lower == "true" || lower == "yes" || lower == "1" {
                    return true
                } else if lower == "false" || lower == "no" || lower == "0" {
                    return false
                }
            }
        case "Date":
            if let date = value as? Date {
                return date
            } else if let str = value as? String {
                let isoFormatter = ISO8601DateFormatter()
                return isoFormatter.date(from: str)
            }
        case "Data":
            if let data = value as? Data {
                return data
            } else if let str = value as? String, let data = Data(base64Encoded: str) {
                return data
            }
        case "UIImage":
            if let image = value as? UIImage {
                return image.pngData()
            } else if let data = value as? Data {
                return data
            }
        case "PDFDocument":
            if let pdf = value as? PDFDocument {
                return pdf.dataRepresentation()
            } else if let data = value as? Data {
                return data
            }
        default:
            return nil
        }
        return nil
    }
    
    /// Universal casting logic for common types.
    static func castUniversal(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        if let stringValue = value as? String {
            return stringValue
        } else if let numberValue = value as? NSNumber {
            return numberValue
        } else if let dateValue = value as? Date {
            return dateValue
        } else if let dataValue = value as? Data {
            return dataValue
        } else if let imageValue = value as? UIImage {
            return imageValue.pngData()
        } else if let pdfValue = value as? PDFDocument {
            return pdfValue.dataRepresentation()
        }
        return nil
    }
}

/// Policy di migrazione per ManagedRelationshipProperty (campo object).
@objc(MigrationV1RelationshipPropertyPolicy)
public class MigrationV1RelationshipPropertyPolicy: NSEntityMigrationPolicy {
    public override func createDestinationInstances(
        forSource sInstance: NSManagedObject,
        in mapping: NSEntityMapping,
        manager: NSMigrationManager
    ) throws {
        // Create the destination instance manually
        guard let destName = mapping.destinationEntityName else { return }
        let dInstance = NSEntityDescription.insertNewObject(forEntityName: destName, into: manager.destinationContext)

        // Copy the "name" attribute if present
        if let name = sInstance.value(forKey: "name") as? String {
            dInstance.setValue(name, forKey: "name")
        }

        // Read the legacy "object" value
        let legacyObject = sInstance.value(forKey: "object")

        // Transform using universal casting logic
        let transformedValue = MigrationV1EntityPropertyPolicy.castUniversal(legacyObject)
        if let valueToSet = transformedValue {
            dInstance.setValue(valueToSet, forKey: "object")
        }

        manager.associate(sourceInstance: sInstance, withDestinationInstance: dInstance, for: mapping)
    }
}

/// Policy di migrazione per ManagedActionProperty (campo object).
///
@objc(MigrationV1ActionPropertyPolicy)
public class MigrationV1ActionPropertyPolicy: NSEntityMigrationPolicy {
    public override func createDestinationInstances(
        forSource sInstance: NSManagedObject,
        in mapping: NSEntityMapping,
        manager: NSMigrationManager
    ) throws {
        // Create the destination instance manually
        guard let destName = mapping.destinationEntityName else { return }
        let dInstance = NSEntityDescription.insertNewObject(forEntityName: destName, into: manager.destinationContext)

        // Copy the "name" attribute if present
        if let name = sInstance.value(forKey: "name") as? String {
            dInstance.setValue(name, forKey: "name")
        }

        // Read the legacy "object" value
        let legacyObject = sInstance.value(forKey: "object")

        // Transform using universal casting logic
        let transformedValue = MigrationV1EntityPropertyPolicy.castUniversal(legacyObject)
        if let valueToSet = transformedValue {
            dInstance.setValue(valueToSet, forKey: "object")
        }

        manager.associate(sourceInstance: sInstance, withDestinationInstance: dInstance, for: mapping)
    }
}
