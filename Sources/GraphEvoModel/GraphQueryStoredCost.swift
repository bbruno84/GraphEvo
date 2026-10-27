import Foundation

/// Charges stored user-value payloads before decoding typed envelopes. This is not a resident-memory cap.
package enum GraphQueryStoredCost {
    package static func charge(_ bytes: Int, remaining: inout Int) throws {
        guard bytes <= remaining else { throw GraphQueryError.budgetExceeded(.propertyBytes) }
        remaining -= bytes
    }
    package static func charge(_ value: GraphValue, remaining: inout Int) throws {
        try charge(1, remaining: &remaining)
        switch value {
        case .data(let bytes): try charge(bytes.count, remaining: &remaining)
        case .encoded(let value): try charge(value.data.count, remaining: &remaining); try charge(value.codec.utf8.count, remaining: &remaining)
        case .string(let text): try charge(text.utf8.count, remaining: &remaining)
        case .url(let url): try charge(url.absoluteString.utf8.count, remaining: &remaining)
        case .array(let values): for value in values { try charge(value, remaining: &remaining) }
        case .object(let values): for (key, value) in values { try charge(key.utf8.count, remaining: &remaining); try charge(value, remaining: &remaining) }
        default: try charge(16, remaining: &remaining)
        }
    }
}
