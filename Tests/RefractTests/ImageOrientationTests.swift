import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Refract

final class ImageOrientationTests: XCTestCase {
    func testSaveOriginalAsBakesEXIFRotationIntoPixels() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("refract-orientation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("camera.jpg")
        let destination = folder.appendingPathComponent("portrait.png")

        let width = 48, height = 24
        let rgb: [UInt8] = (0..<(width * height)).flatMap { i -> [UInt8] in
            i % width < width / 2 ? [255, 0, 0] : [0, 0, 255]
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgb) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoded, image, [kCGImagePropertyOrientation: 6,
                                                   kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoded))

        try ImageFiles.export(source, to: destination, format: .png, quality: 1, metadataSource: source)
        let result = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        XCTAssertEqual(info[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(result, 0, nil))
        XCTAssertEqual(pixels.width, height)
        XCTAssertEqual(pixels.height, width)
        let top = try color(in: pixels, atY: 8)
        let bottom = try color(in: pixels, atY: width - 8)
        XCTAssertGreaterThan(top[0], top[2] + 80)
        XCTAssertGreaterThan(bottom[2], bottom[0] + 80)
    }

    private func color(in image: CGImage, atY y: Int) throws -> [Int] {
        let sample = try XCTUnwrap(image.cropping(to: .init(x: image.width / 2, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.map(Int.init)
    }
}
