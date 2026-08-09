#if canImport(UIKit)

import UIKit

enum GraphPlatformImageEncoder {
    static func pngData(from value: Any) -> Data? {
        (value as? UIImage)?.pngData()
    }
}

#endif
