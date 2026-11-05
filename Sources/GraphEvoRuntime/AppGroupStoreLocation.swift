import Foundation

/// A package-only capability rooted in an entitled App Group container.
package struct AppGroupStoreLocation: Sendable, Equatable {
    static let namespace = "GraphEvo-AppGroup-v1"
    private let root: URL

    package init(identifier: String) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw StoreRuntimeError.invalidConfiguration("The App Group container is unavailable.")
        }
        self.init(container: container)
    }

    init(container: URL) {
        root = container.standardizedFileURL.resolvingSymlinksInPath()
    }

    package func storeURL(for graphID: UUID) -> URL {
        root.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Self.namespace, isDirectory: true)
            .appendingPathComponent(graphID.uuidString, isDirectory: true)
            .appendingPathComponent("Store.sqlite", isDirectory: false)
    }

    static func isReserved(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.caseInsensitiveCompare(namespace) == .orderedSame }
    }

    package static func rejectUncoordinated(_ url: URL) throws {
        let requested = url.standardizedFileURL
        // Foundation may leave an ancestor alias unresolved when the final
        // component does not exist (e.g. a new backup destination).
        var ancestor = requested
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        guard !isReserved(requested), !isReserved(ancestor.resolvingSymlinksInPath()) else {
            throw StoreRuntimeError.invalidConfiguration("This path is reserved for coordinated App Group graphs.")
        }
    }

    func validate(requested: URL, canonical: URL, graphID: UUID) throws {
        let expected = storeURL(for: graphID).path
        guard requested.standardizedFileURL.path == expected, canonical.path == expected else {
            throw StoreRuntimeError.invalidConfiguration("The App Group graph requires its exact dedicated store path.")
        }
    }
}
