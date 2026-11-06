import AppKit
import SwiftUI
import Testing
@testable import PrtScn

@MainActor
struct PixelateTests {
    private static func gradientImage() -> NSImage {
        let size = 240
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<size {
            context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(size), green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: size))
        }
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: size, height: size))
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        Array(image.dataProvider!.data! as Data)
    }

    @Test func mosaicIsShuffledButStableForOneAnnotation() throws {
        let model = EditorModel(image: Self.gradientImage(),
                                workingURL: FileManager.default.temporaryDirectory.appendingPathComponent("px.png"),
                                captureScale: 1)
        var box = Annotation(kind: .pixelate, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 240, y: 60),
                             color: .black, lineWidth: 1, fontSize: 1)
        let first = try #require(model.pixelatedRegion(for: box))
        let again = try #require(model.pixelatedRegion(for: box))
        #expect(Self.bytes(first) == Self.bytes(again))

        box.id = UUID()
        let reseeded = try #require(model.pixelatedRegion(for: box))
        #expect(Self.bytes(first) != Self.bytes(reseeded))

        let leftColumn = Self.bytes(first).prefix(4)
        let rightColumn = Self.bytes(first).dropFirst((first.width - 1) * 4).prefix(4)
        #expect(leftColumn != rightColumn, "a monotonic gradient would survive an unshuffled mosaic")
    }
}
