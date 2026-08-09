import Foundation

/// Resolves resources in both Swift Package Manager and the standalone Xcode
/// XCTest target. `Bundle.module` is generated only for SwiftPM targets.
final class GraphTestsBundleToken {}

extension Bundle {
    static var graphTests: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle(for: GraphTestsBundleToken.self)
#endif
    }

    static func graphTestResource(named name: String, withExtension pathExtension: String) -> URL? {
        let bundle = graphTests
        if let directURL = bundle.url(forResource: name, withExtension: pathExtension) {
            return directURL
        }

        guard let resourceURL = bundle.resourceURL,
              let resourceEnumerator = FileManager.default.enumerator(
                  at: resourceURL,
                  includingPropertiesForKeys: nil
              ) else {
            return nil
        }

        let expectedName = "\(name).\(pathExtension)"
        return resourceEnumerator
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == expectedName }
    }
}
