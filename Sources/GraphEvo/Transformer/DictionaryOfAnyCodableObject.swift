//
//  DictionaryOfAnyCodableObject.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 04/09/25.
//

import Foundation

@objc(DictionaryOfAnyCodableObject)
public final class DictionaryOfAnyCodableObject: NSObject, NSSecureCoding, Codable, Collection {
    
    public static var supportsSecureCoding: Bool = true
    
    public let items: [String: AnyCodableObject]
    
    public init(_ items: [String: AnyCodableObject]) {
        self.items = items
    }
    
    public required init?(coder: NSCoder) {
        guard let dict = coder.decodeObject(of: [NSDictionary.self, NSString.self, AnyCodableObject.self], forKey: "items") as? [String: AnyCodableObject] else {
            return nil
        }
        self.items = dict
    }
    
    public func encode(with coder: NSCoder) {
        coder.encode(items, forKey: "items")
    }
    
    public required init(from decoder: Decoder) throws {
        self.items = try [String: AnyCodableObject](from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try items.encode(to: encoder)
    }
    
    // MARK: - Collection
    public typealias Index = Dictionary<String, AnyCodableObject>.Index
    public var startIndex: Index { items.startIndex }
    public var endIndex: Index { items.endIndex }
    public func index(after i: Index) -> Index { items.index(after: i) }
    public subscript(position: Index) -> (key: String, value: AnyCodableObject) { items[position] }
}
