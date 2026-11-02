import CoreData
import Foundation
import GraphEvoModel
import GraphEvoStore

/// S04 value storage. All access stays on the facade's admitted context queue.
enum GraphNativePropertyStorage {
    static let identifier = "GraphEvo.v2.schema.4"
    static let kindKey = "ge2ValueKind", encodingKey = "ge2ValueEncoding"
    static let keyPrefix = "__graphevo_v2.key."
    static let slots: [(String, NSAttributeType)] = [
        ("ge2Bool", .booleanAttributeType), ("ge2Int64", .integer64AttributeType),
        ("ge2Double", .doubleAttributeType), ("ge2String", .stringAttributeType),
        ("ge2Date", .dateAttributeType), ("ge2UUID", .UUIDAttributeType),
        ("ge2URI", .URIAttributeType), ("ge2Bytes", .binaryDataAttributeType)
    ]
    enum Kind: Int16 { case null, boolean, integer, unsigned, floating, decimal, string, data, date, url, uuid, array, object, encoded }
    struct Prepared {
        let kind: Kind
        let encoding: Int16
        let field: String?
        let value: Any?
    }
    static func makeModel() -> NSManagedObjectModel {
        let model = GraphRuntimeSchema.makeNativeModel()
        for name in [ModelIdentifier.entityPropertyName, ModelIdentifier.relationshipPropertyName, ModelIdentifier.actionPropertyName] {
            let entity = model.entitiesByName[name]!
            for (key, type) in [(kindKey, NSAttributeType.integer16AttributeType), (encodingKey, .integer16AttributeType)] + slots {
                let attribute = NSAttributeDescription(); attribute.name = key; attribute.attributeType = type; attribute.isOptional = true
                if key == "ge2Bytes" { attribute.allowsExternalBinaryDataStorage = true }
                entity.properties.append(attribute)
            }
            let indexKeys = [["name", "node"]] + ["ge2Int64", "ge2Double", "ge2String", "ge2Date", "ge2UUID"].map { ["name", kindKey, encodingKey, $0] }
            entity.indexes = indexKeys.enumerated().map { offset, keys in
                NSFetchIndexDescription(name: name + "_ge2_value_" + String(offset), elements: keys.map {
                    NSFetchIndexElementDescription(property: entity.propertiesByName[$0]!, collationType: .binary)
                })
            }
        }
        model.versionIdentifiers = [identifier]; return model
    }
    static func enabled(_ context: NSManagedObjectContext) -> Bool {
        context.persistentStoreCoordinator?.managedObjectModel.versionIdentifiers == [AnyHashable(identifier)]
    }
    static func physicalKey(_ key: String) -> String {
        key.utf8.contains(0) ? keyPrefix + Data(key.utf8).base64EncodedString() : key
    }
    static func logicalKey(_ row: NSManagedObject) throws -> String {
        guard let name = row.value(forKey: "name") as? String else { throw GraphStoreError.corruptIdentity }
        guard name.hasPrefix(keyPrefix), row.value(forKey: kindKey) != nil else { return name }
        guard let bytes = Data(base64Encoded: String(name.dropFirst(keyPrefix.count))),
              let key = String(data: bytes, encoding: .utf8), key.utf8.contains(0), physicalKey(key) == name else {
            throw GraphStoreError.corruptIdentity
        }
        return key
    }
    static func prepare(_ value: GraphValue) throws -> Prepared {
        func native(_ kind: Kind, _ field: String? = nil, _ value: Any? = nil) -> Prepared { .init(kind: kind, encoding: 0, field: field, value: value) }
        func envelope(_ kind: Kind) throws -> Prepared { .init(kind: kind, encoding: 1, field: "ge2Bytes", value: try GraphValueCodec.encode(value)) }
        switch value {
        case .null: return native(.null)
        case .boolean(let v): return native(.boolean, "ge2Bool", v)
        case .integer(let v): return native(.integer, "ge2Int64", v)
        case .unsignedInteger(let v):
            let string = String(v)
            return native(.unsigned, "ge2String", String(repeating: "0", count: 20 - string.count) + string)
        case .floatingPoint(let v):
            guard v.isFinite else { throw GraphModelError.invalidValue }
            return v == 0 && v.sign == .minus ? try envelope(.floating) : native(.floating, "ge2Double", v)
        case .decimal(let v): guard !v.isNaN else { throw GraphModelError.invalidValue }; return try envelope(.decimal)
        case .string(let v): return v.utf8.contains(0) ? try envelope(.string) : native(.string, "ge2String", v)
        case .data(let v): return native(.data, "ge2Bytes", v)
        case .date(let v):
            let interval = v.timeIntervalSinceReferenceDate
            guard interval.isFinite else { throw GraphModelError.invalidValue }
            return interval == 0 && interval.sign == .minus ? try envelope(.date) : native(.date, "ge2Date", v)
        case .uuid(let v): return native(.uuid, "ge2UUID", v)
        case .url(let v): return v.baseURL != nil ? try envelope(.url) : native(.url, "ge2URI", v)
        case .array: return try envelope(.array)
        case .object: return try envelope(.object)
        case .encoded: return try envelope(.encoded)
        }
    }
    private static func requiresEnvelope(_ value: GraphValue) -> Bool {
        switch value {
        case .decimal, .array, .object, .encoded: return true
        case .string(let string): return string.utf8.contains(0)
        case .floatingPoint(let number): return number == 0 && number.sign == .minus
        case .date(let date): return date.timeIntervalSinceReferenceDate == 0 && date.timeIntervalSinceReferenceDate.sign == .minus
        case .url(let url): return url.baseURL != nil
        default: return false
        }
    }
    static func kind(_ value: GraphValue) -> Kind {
        switch value {
        case .null: return .null; case .boolean: return .boolean; case .integer: return .integer
        case .unsignedInteger: return .unsigned; case .floatingPoint: return .floating; case .decimal: return .decimal
        case .string: return .string; case .data: return .data; case .date: return .date; case .url: return .url
        case .uuid: return .uuid; case .array: return .array; case .object: return .object; case .encoded: return .encoded
        }
    }
    static func read(_ row: NSManagedObject, charge: ((Int) throws -> Void)? = nil) throws -> GraphValue {
        guard let raw = row.value(forKey: kindKey) as? NSNumber, let kind = Kind(rawValue: raw.int16Value),
              raw.doubleValue == Double(kind.rawValue), let encoding = row.value(forKey: encodingKey) as? NSNumber,
              encoding.doubleValue == 0 || encoding.doubleValue == 1, row.value(forKey: "object") == nil else { throw GraphStoreError.corruptIdentity }
        let field: String?
        if encoding.intValue == 1 { field = "ge2Bytes" }
        else {
            switch kind {
            case .null: field = nil
            case .boolean: field = "ge2Bool"; case .integer: field = "ge2Int64"
            case .unsigned, .string: field = "ge2String"; case .floating: field = "ge2Double"
            case .data: field = "ge2Bytes"; case .date: field = "ge2Date"
            case .uuid: field = "ge2UUID"; case .url: field = "ge2URI"
            default: throw GraphStoreError.corruptIdentity
            }
        }
        for (slot, _) in slots {
            guard (row.value(forKey: slot) != nil) == (slot == field) else { throw GraphStoreError.corruptIdentity }
        }
        if encoding.intValue == 1 {
            guard let bytes = row.value(forKey: "ge2Bytes") as? Data else { throw GraphStoreError.corruptIdentity }
            try charge?(1 + bytes.count)
            let value = try GraphValueCodec.decode(bytes)
            guard self.kind(value) == kind, requiresEnvelope(value) else { throw GraphStoreError.corruptIdentity }
            return value
        }
        let result: GraphValue
        switch kind {
        case .null: result = .null
        case .boolean: guard let v = row.value(forKey: field!) as? NSNumber else { throw GraphStoreError.corruptIdentity }; result = .boolean(v.boolValue)
        case .integer: guard let v = row.value(forKey: field!) as? NSNumber else { throw GraphStoreError.corruptIdentity }; result = .integer(v.int64Value)
        case .floating: guard let v = row.value(forKey: field!) as? NSNumber, v.doubleValue.isFinite else { throw GraphStoreError.corruptIdentity }; result = .floatingPoint(v.doubleValue)
        case .unsigned:
            guard let string = row.value(forKey: field!) as? String, string.utf8.count == 20,
                  string.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(string),
                  String(repeating: "0", count: 20 - String(value).count) + String(value) == string else { throw GraphStoreError.corruptIdentity }
            result = .unsignedInteger(value)
        case .string: guard let v = row.value(forKey: field!) as? String, !v.utf8.contains(0) else { throw GraphStoreError.corruptIdentity }; result = .string(v)
        case .data: guard let v = row.value(forKey: field!) as? Data else { throw GraphStoreError.corruptIdentity }; result = .data(v)
        case .date: guard let v = row.value(forKey: field!) as? Date, v.timeIntervalSinceReferenceDate.isFinite else { throw GraphStoreError.corruptIdentity }; result = .date(v)
        case .uuid: guard let v = row.value(forKey: field!) as? UUID else { throw GraphStoreError.corruptIdentity }; result = .uuid(v)
        case .url: guard let v = row.value(forKey: field!) as? URL, v.baseURL == nil else { throw GraphStoreError.corruptIdentity }; result = .url(v)
        default: throw GraphStoreError.corruptIdentity
        }
        guard !requiresEnvelope(result) else { throw GraphStoreError.corruptIdentity }
        if let charge { var remaining = Int.max; try GraphQueryStoredCost.charge(result, remaining: &remaining); try charge(Int.max - remaining) }
        return result
    }
    static func keys(_ facade: Node) throws -> Set<String> {
        var result = Set<String>()
        for row in facade.node.propertySet {
            let key = try logicalKey(row)
            if row.value(forKey: kindKey) != nil {
                guard !key.hasPrefix(GraphTypedStoreAdapter.prefix), result.insert(key).inserted else { throw GraphStoreError.corruptIdentity }
            } else if !key.hasPrefix(GraphTypedStoreAdapter.prefix) { throw GraphStoreError.corruptIdentity }
        }
        return result
    }
    static func properties(_ facade: Node, keys: Set<String>?, charge: ((Int) throws -> Void)? = nil) throws -> [String: GraphValue] {
        var result: [String: GraphValue] = [:]
        for row in facade.node.propertySet {
            let key = try logicalKey(row)
            if row.value(forKey: kindKey) == nil {
                guard key.hasPrefix(GraphTypedStoreAdapter.prefix), key != keyPrefix else { throw GraphStoreError.corruptIdentity }
                continue
            }
            guard !key.hasPrefix(GraphTypedStoreAdapter.prefix) else { throw GraphStoreError.corruptIdentity }
            if let keys, !keys.contains(key) { continue }
            guard result[key] == nil else { throw GraphStoreError.corruptIdentity }
            try charge?(key.utf8.count)
            result[key] = try read(row, charge: charge)
        }
        return result
    }
    static func write(_ prepared: Prepared, key: String, to facade: Node) throws {
        let matches = try facade.node.propertySet.filter { try logicalKey($0) == key }
        guard matches.count <= 1 else { throw GraphStoreError.corruptIdentity }
        let row: ManagedProperty
        if let existing = matches.first { row = existing }
        else {
            Swift.type(of: facade.node).createProperty(name: physicalKey(key), object: NSNull(), node: facade.node, managedObjectContext: facade.node.managedObjectContext!)
            guard let inserted = facade.node.propertySet.first(where: { $0.name == physicalKey(key) }) else { throw GraphStoreError.corruptIdentity }
            row = inserted
        }
        row.setValue(nil, forKey: "object")
        for (slot, _) in slots { row.setValue(nil, forKey: slot) }
        row.setValue(prepared.kind.rawValue, forKey: kindKey); row.setValue(prepared.encoding, forKey: encodingKey)
        if let field = prepared.field { row.setValue(prepared.value, forKey: field) }
    }
    static func remove(_ key: String, from facade: Node) throws {
        let matches = try facade.node.propertySet.filter { try logicalKey($0) == key }
        guard matches.count <= 1 else { throw GraphStoreError.corruptIdentity }
        matches.first?.delete()
    }
}
