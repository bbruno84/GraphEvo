#if !canImport(UIKit) && !canImport(AppKit)

import Foundation

enum GraphPlatformImageEncoder {
    static let legacyImageClasses: [AnyClass] = []

    static func pngData(from value: Any) -> Data? {
        nil
    }
}

#endif
