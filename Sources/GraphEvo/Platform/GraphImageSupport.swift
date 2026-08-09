import Foundation

/// Converts platform image objects to the PNG data used by GraphEvo storage.
enum GraphImageSupport {
    static func pngData(from value: Any) -> Data? {
        GraphPlatformImageEncoder.pngData(from: value)
    }
}
