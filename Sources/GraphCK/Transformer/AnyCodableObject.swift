//
//  AnyCodableObject.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//


import Foundation

@objc(AnyCodableObject)
public final class AnyCodableObject: NSObject, NSSecureCoding, Codable {
    
    public static var supportsSecureCoding: Bool = true
    
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    // MARK: - NSSecureCoding
    
    public func encode(with coder: NSCoder) {
        coder.encode(value as? NSObject, forKey: "value")
    }
    
    public required init?(coder: NSCoder) {
        self.value = coder.decodeObject(of: [
            NSString.self,
            NSNumber.self,
            NSData.self,
            NSDate.self,
            NSURL.self,
            NSArray.self,
            NSDictionary.self,
            AnyCodableObject.self,
            NSArrayOfAnyCodableObject.self,
            DictionaryOfAnyCodableObject.self
        ], forKey: "value")
    }
    
    // MARK: - Codable
    
    public required convenience init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let string = try? container.decode(String.self) {
            self.init(string)
        } else if let int = try? container.decode(Int.self) {
            self.init(int)
        } else if let double = try? container.decode(Double.self) {
            self.init(double)
        } else if let bool = try? container.decode(Bool.self) {
            self.init(bool)
        } else if let date = try? container.decode(Date.self) {
            self.init(date)
        } else if let data = try? container.decode(Data.self) {
            self.init(data)
        } else if let url = try? container.decode(URL.self) {
            self.init(url)
        } else if let array = try? container.decode([AnyCodableObject].self) {
            self.init(array)
        } else if let dict = try? container.decode([String: AnyCodableObject].self) {
            self.init(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value in AnyCodableObject")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as Date: try container.encode(v)
        case let v as Data: try container.encode(v)
        case let v as URL: try container.encode(v)
        case let v as [AnyCodableObject]: try container.encode(v)
        case let v as [String: AnyCodableObject]: try container.encode(v)
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported value in AnyCodableObject"))
        }
    }
}
