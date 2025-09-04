//
//  NSArrayOfAnyCodableObject.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//


import Foundation

@objc(NSArrayOfAnyCodableObject)
public final class NSArrayOfAnyCodableObject: NSObject, NSSecureCoding, Codable {
    
    public static var supportsSecureCoding: Bool = true
    
    public let items: [AnyCodableObject]
    
    public init(_ items: [AnyCodableObject]) {
        self.items = items
    }
    
    public required init?(coder: NSCoder) {
        guard let array = coder.decodeObject(of: [NSArray.self, AnyCodableObject.self], forKey: "items") as? [AnyCodableObject] else {
            return nil
        }
        self.items = array
    }
    
    public func encode(with coder: NSCoder) {
        coder.encode(items, forKey: "items")
    }
    
    public required init(from decoder: Decoder) throws {
        self.items = try [AnyCodableObject](from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try items.encode(to: encoder)
    }
}
