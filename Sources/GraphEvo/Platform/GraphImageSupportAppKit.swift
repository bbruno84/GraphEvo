#if canImport(AppKit)

import AppKit

enum GraphPlatformImageEncoder {
    static let legacyImageClasses: [AnyClass] = [NSImage.self]

    static func pngData(from value: Any) -> Data? {
        guard let image = value as? NSImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

#endif
