import Foundation

/// Resolves resources in both Swift Package Manager and the standalone Xcode
/// XCTest target. `Bundle.module` is generated only for SwiftPM targets.
final class GraphTestsBundleToken {}

extension Bundle {
    static var graphTests: Bundle {
        Bundle(for: GraphTestsBundleToken.self)
    }
}
