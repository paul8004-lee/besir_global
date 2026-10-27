import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The size bounds every shared image must meet before it is stored or sent. Declared once so the shrink and the vision client agree.
enum SharedImage {
    static let maxBytes = 1_048_576
    static let maxLongEdge = 2048

    /// The size of the image a base64 string holds, from its length and padding, without decoding it.
    static func decodedByteCount(ofBase64 base64: String) -> Int {
        let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
        return max(0, base64.utf8.count / 4 * 3 - padding)
    }
}

/// Brings a shared image down to a JPEG the Worker can read cheaply (SPEC-SHARE-001).
/// Uses ImageIO thumbnails, so the full-size bitmap is never decoded; the share extension has little memory.
enum ImageShrink {
    private static let qualities: [Double] = [0.8, 0.65, 0.5, 0.35]

    /// JPEG data of at most `maxBytes` bytes and `maxLongEdge` pixels on the long edge, or nil when `data` is not an image
    /// or cannot be brought under the byte bound. A smaller image keeps its size. Transparent areas turn white, not black.
    static func jpeg(from data: Data, maxLongEdge: Int = SharedImage.maxLongEdge, maxBytes: Int = SharedImage.maxBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let firstEdge = min(maxLongEdge, max(width, height))
        // One retry at half the long edge when no quality fits the byte bound.
        for edge in [firstEdge, firstEdge / 2] where edge > 0 {
            guard let thumbnail = thumbnail(of: source, longEdge: edge), let flat = flattenedOnWhite(thumbnail) else { return nil }
            for quality in qualities {
                if let encoded = encode(flat, quality: quality), encoded.count <= maxBytes { return encoded }
            }
        }
        return nil
    }

    private static func thumbnail(of source: CGImageSource, longEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
