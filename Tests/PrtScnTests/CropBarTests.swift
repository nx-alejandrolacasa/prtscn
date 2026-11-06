import AppKit
import SwiftUI
import Testing
@testable import PrtScn

@MainActor
struct CropBarTests {
    private static func model() -> EditorModel {
        let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        return EditorModel(image: image,
                           workingURL: FileManager.default.temporaryDirectory.appendingPathComponent("crop.png"),
                           captureScale: 1)
    }

    @Test func typedSizeIsPlacedAtTheAnchorAndClamped() {
        let model = Self.model()
        model.beginCrop()
        model.setCropAnchor(.bottomTrailing)
        model.cropWidth = 100
        model.cropHeight = 50
        #expect(model.cropRect == CGRect(x: 300, y: 250, width: 100, height: 50))

        model.cropWidth = 9999
        #expect(model.cropRect == CGRect(x: 0, y: 250, width: 400, height: 50))

        model.setCropAnchor(.center)
        #expect(model.cropRect == CGRect(x: 0, y: 125, width: 400, height: 50))
    }

    @Test func resizingKeepsTheAnchoredCornerOfADrawnRegion() {
        let model = Self.model()
        model.beginCrop()
        model.cropRect = CGRect(x: 100, y: 100, width: 80, height: 80)
        model.setCropAnchor(.topLeading)
        #expect(model.cropRect == CGRect(x: 0, y: 0, width: 80, height: 80))

        model.cropRect = CGRect(x: 100, y: 100, width: 80, height: 80)
        model.cropAnchor = .topLeading
        model.cropWidth = 120
        #expect(model.cropRect == CGRect(x: 100, y: 100, width: 120, height: 80))
    }
}
