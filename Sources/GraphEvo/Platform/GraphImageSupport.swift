import Foundation

/// Converts platform image objects to the PNG data used by GraphEvo storage.
enum GraphImageSupport {
    /// Classes used by the legacy image archive format on the current platform.
    static var legacyImageClasses: [AnyClass] {
        GraphPlatformImageEncoder.legacyImageClasses
    }

    static func pngData(from value: Any) -> Data? {
        GraphPlatformImageEncoder.pngData(from: value)
    }
}
