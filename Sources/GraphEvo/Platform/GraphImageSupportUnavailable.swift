#if !canImport(UIKit) && !canImport(AppKit)

import Foundation

enum GraphPlatformImageEncoder {
    static func pngData(from value: Any) -> Data? {
        nil
    }
}

#endif
