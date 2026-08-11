#if canImport(UIKit)

import UIKit

enum GraphPlatformImageEncoder {
    static let legacyImageClasses: [AnyClass] = [UIImage.self]

    static func pngData(from value: Any) -> Data? {
        (value as? UIImage)?.pngData()
    }
}

#endif
