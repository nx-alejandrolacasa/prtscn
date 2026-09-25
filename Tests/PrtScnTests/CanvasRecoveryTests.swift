import AppKit
import SwiftUI
import Testing
@testable import PrtScn

@MainActor
struct CanvasRecoveryTests {
    private let package = FileManager.default.temporaryDirectory
        .appendingPathComponent("recovery-test-\(UUID().uuidString).prtscn", isDirectory: true)

    private static func whiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func document(_ annotations: [Annotation]) -> ProjectDocument {
        ProjectDocument(captureScale: 2, nextCounter: 4, annotations: annotations)
    }

    @Test func snapshotReopensAsTheSameCanvas() throws {
        var box = Annotation(kind: .roundedRect, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 80),
                             color: Color(hex: "#FF3B30"), lineWidth: 6, fontSize: 36)
        box.text = "Service"
        var arrow = Annotation(kind: .line, start: CGPoint(x: 110, y: 50), end: CGPoint(x: 190, y: 90),
                               color: Color(hex: "#007AFF"), lineWidth: 6, fontSize: 36)
        arrow.startBinding = ShapeBinding(shapeID: box.id, side: .right)
        arrow.bend = .corner

        let recovery = CanvasRecovery(adopting: package)
        recovery.save(document: document([box, arrow]), image: { Self.whiteImage(width: 200, height: 100) },
                      imageGeneration: 1, origin: nil)
        CanvasRecovery.waitForPendingWrites()

        let (image, restored) = try ProjectDocument.read(from: package)
        #expect(image.representations.first?.pixelsWide == 200)
        #expect(restored.nextCounter == 4)
        #expect(restored.annotations.map(\.id) == [box.id, arrow.id])
        #expect(restored.annotations[0].text == "Service")
        #expect(restored.annotations[0].color.hexString == "#FF3B30")
        #expect(restored.annotations[1].startBinding == arrow.startBinding)
        #expect(restored.annotations[1].bend == .corner)

        recovery.discard()
        CanvasRecovery.waitForPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func cropReplacesTheStoredImage() throws {
        let recovery = CanvasRecovery(adopting: package)
        defer { recovery.discard(); CanvasRecovery.waitForPendingWrites() }
        recovery.save(document: document([]), image: { Self.whiteImage(width: 200, height: 100) },
                      imageGeneration: 1, origin: nil)
        recovery.save(document: document([]), image: { Self.whiteImage(width: 50, height: 40) },
                      imageGeneration: 2, origin: nil)
        CanvasRecovery.waitForPendingWrites()

        let (image, _) = try ProjectDocument.read(from: package)
        #expect(image.representations.first?.pixelsWide == 50)
    }
}
