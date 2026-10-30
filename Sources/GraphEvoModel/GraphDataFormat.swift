import Foundation

/// Application record formats, independent of native schema, codec and app versions.
/// Read compatibility is explicit; serialization writes only the current format.
public struct GraphDataFormat: Sendable, Equatable, Hashable {
    public let currentVersion: Int64?
    public let readableVersions: Set<Int64>
    public let acceptsUndeclared: Bool

    public static let undeclared = Self()

    private init() {
        currentVersion = nil; readableVersions = []; acceptsUndeclared = true
    }

    public init(currentVersion: Int64, readableVersions: Set<Int64>? = nil,
                acceptsUndeclared: Bool = false) throws {
        let readable = readableVersions ?? [currentVersion]
        guard currentVersion >= 0, readable.contains(currentVersion), readable.allSatisfy({ $0 >= 0 }) else {
            throw GraphDataFormatError.invalidDeclaration
        }
        self.currentVersion = currentVersion
        self.readableVersions = readable
        self.acceptsUndeclared = acceptsUndeclared
    }

    public func canRead(_ version: Int64?) -> Bool {
        version.map { readableVersions.contains($0) } ?? acceptsUndeclared
    }

    public func canWrite(_ version: Int64?) -> Bool { version == currentVersion }
}

public enum GraphDataFormatError: Error, Sendable, Equatable {
    case invalidDeclaration
    case invalidVersion
    case unreadableVersion(Int64?)
    case unwritableVersion(Int64?)
}

extension GraphDataFormatError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDeclaration: return "The data format declaration is invalid."
        case .invalidVersion: return "Record data versions must be nonnegative."
        case .unreadableVersion: return "The record data version is not declared readable by this model."
        case .unwritableVersion: return "The record data version does not match the model's current format."
        }
    }
}
