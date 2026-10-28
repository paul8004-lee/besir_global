import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import besir

/// Images are generated here with CoreGraphics; no binary fixture is committed.
enum ShareTestImages {
    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    static func encoded(_ image: CGImage, as type: UTType, quality: Double = 0.9) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A poster-like picture: bands of colour and block shapes, so it compresses like a screenshot rather than like noise.
    static func poster(width: Int, height: Int) -> Data {
        let image = bitmap(width: width, height: height) { context in
            for band in 0..<16 {
                context.setFillColor(red: CGFloat(band) / 16, green: 0.4, blue: 1 - CGFloat(band) / 16, alpha: 1)
                context.fill(CGRect(x: 0, y: band * height / 16, width: width, height: height / 16 + 1))
            }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            for block in 0..<40 {
                context.fill(CGRect(x: 80 + block * 60, y: height / 3, width: 30, height: height / 4))
            }
        }
        return encoded(image, as: .jpeg)
    }

    /// Random pixels: the worst case for any compressor.
    static func noise(width: Int, height: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 1] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 2] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 3] = 255
        }
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()!
        }
        return encoded(image, as: .png)
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The RGB of one pixel of an encoded image (top-left origin).
    static func rgb(of data: Data, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (Int(pixel[0]), Int(pixel[1]), Int(pixel[2])) : nil
    }
}

/// SPEC-SHARE-001 AC-SHARE-004: every image that reaches the Worker is JPEG, at most 1 MiB and 2048 px on the long edge.
final class ShareImageShrinkTests: XCTestCase {
    func testAC_SHARE_004_largePhotoBecomesJpegWithinBounds() throws {
        let source = ShareTestImages.poster(width: 4032, height: 3024)
        let shrunk = try XCTUnwrap(ImageShrink.jpeg(from: source))
        XCTAssertLessThanOrEqual(shrunk.count, SharedImage.maxBytes)
        XCTAssertEqual(Array(shrunk.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG magic bytes")
        let size = try XCTUnwrap(ShareTestImages.pixelSize(of: shrunk))
        XCTAssertEqual(max(size.width, size.height), 2048)
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 1536)
    }

    func testAC_SHARE_004_smallImageKeepsItsSize() throws {
        let source = ShareTestImages.poster(width: 300, height: 200)
        let shrunk = try XCTUnwrap(ImageShrink.jpeg(from: source))
        let size = try XCTUnwrap(ShareTestImages.pixelSize(of: shrunk))
        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 200)
    }

    func testAC_SHARE_004_dataThatIsNotAnImageGivesNil() {
        XCTAssertNil(ImageShrink.jpeg(from: Data("not an image".utf8)))
        XCTAssertNil(ImageShrink.jpeg(from: Data()))
    }

    func testAC_SHARE_004_noiseThatCannotFitTheByteBoundGivesNil() {
        let source = ShareTestImages.noise(width: 600, height: 400)
        XCTAssertNil(ImageShrink.jpeg(from: source, maxBytes: 10_000))
    }

    func testAC_SHARE_004_transparentAreaTurnsWhiteNotBlack() throws {
        let source = ShareTestImages.encoded(ShareTestImages.bitmap(width: 200, height: 200) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
        }, as: .png)
        let shrunk = try XCTUnwrap(ImageShrink.jpeg(from: source))
        let clear = try XCTUnwrap(ShareTestImages.rgb(of: shrunk, x: 10, y: 100))
        XCTAssertGreaterThan(clear.r, 240)
        XCTAssertGreaterThan(clear.g, 240)
        XCTAssertGreaterThan(clear.b, 240)
        let red = try XCTUnwrap(ShareTestImages.rgb(of: shrunk, x: 150, y: 100))
        XCTAssertGreaterThan(red.r, 200)
        XCTAssertLessThan(red.g, 60)
    }
}
