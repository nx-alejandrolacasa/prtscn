import AppKit
import SwiftUI
import Testing
@testable import PrtScn

@MainActor
struct LastCaptureTests {
    @Test func keptCaptureReopensWithItsAnnotations() throws {
        let store = LastCapture(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("last-capture-test-\(UUID().uuidString).prtscn", isDirectory: true))
        #expect(!store.exists)

        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        let arrow = Annotation(kind: .line, start: .zero, end: CGPoint(x: 20, y: 10),
                               color: Color(hex: "#FF3B30"), lineWidth: 6, fontSize: 36)
        store.keep(ProjectDocument(captureScale: 2, nextCounter: 3, annotations: [arrow])) { png }
        store.waitForPendingWrites()

        #expect(store.exists)
        let (image, document) = try ProjectDocument.read(from: store.url)
        #expect(image.representations.first?.pixelsWide == 40)
        #expect(document.annotations.map(\.id) == [arrow.id])
        #expect(document.nextCounter == 3)

        store.clear()
        #expect(!store.exists)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }
}

struct LegibleLabelColorTests {
    @Test func lightBadgesGetDarkNumerals() {
        #expect(NSColor(Color(hex: "#FFFFFF")).legibleLabelColor == .black)
        #expect(NSColor(Color(hex: "#FFCC00")).legibleLabelColor == .black)
        #expect(NSColor(Color(hex: "#FF3B30")).legibleLabelColor == .white)
        #expect(NSColor(Color(hex: "#000000")).legibleLabelColor == .white)
    }
}

struct SelectionRectTests {
    private let size = CGSize(width: 100, height: 50)

    @Test func rectangleHangsOffTheReleaseTowardThePress() {
        let downRight = ScreenshotService.selectionRect(down: CGPoint(x: 10, y: 90), up: CGPoint(x: 110, y: 40), size: size)
        #expect(downRight == CGRect(x: 10, y: 40, width: 100, height: 50))
        let upLeft = ScreenshotService.selectionRect(down: CGPoint(x: 110, y: 40), up: CGPoint(x: 10, y: 90), size: size)
        #expect(upLeft == CGRect(x: 10, y: 40, width: 100, height: 50))
    }

    @Test func aClickSelectsNoRectangle() {
        #expect(ScreenshotService.selectionRect(down: CGPoint(x: 5, y: 5), up: CGPoint(x: 6, y: 5), size: size) == nil)
    }
}
