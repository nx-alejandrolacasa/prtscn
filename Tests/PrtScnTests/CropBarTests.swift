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

@MainActor
struct EditorUndoTests {
    private static func model() -> EditorModel {
        let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        return EditorModel(image: image,
                           workingURL: FileManager.default.temporaryDirectory.appendingPathComponent("undo.png"),
                           captureScale: 1)
    }

    @Test func undoingACropRestoresTheImageAndTheAnnotations() {
        let model = Self.model()
        let original = model.pixelSize
        model.stampCounter(at: CGPoint(x: 150, y: 120))
        model.beginCrop()
        model.cropRect = CGRect(x: 100, y: 100, width: 80, height: 60)
        model.applyCrop()
        #expect(model.pixelSize == CGSize(width: 80, height: 60))
        #expect(model.annotations[0].start == CGPoint(x: 50, y: 20))

        model.undo()
        #expect(model.pixelSize == original)
        #expect(model.annotations[0].start == CGPoint(x: 150, y: 120))

        model.redo()
        #expect(model.pixelSize == CGSize(width: 80, height: 60))
    }

    @Test func deletingAStepRenumbersTheOnesAfterIt() {
        let model = Self.model()
        for x in [10, 20, 30] { model.stampCounter(at: CGPoint(x: x, y: 10)) }
        model.selectedID = model.annotations[1].id
        model.deleteSelected()
        #expect(model.annotations.map(\.number) == [1, 2])
        #expect(model.nextCounter == 3)

        model.undo()
        #expect(model.annotations.map(\.number) == [1, 2, 3])
        #expect(model.nextCounter == 4)
    }
}

@MainActor
struct PointerZoomTests {
    @Test func theSpotUnderThePointerStaysPutWhileZooming() {
        let image = NSImage(size: NSSize(width: 400, height: 100), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let model = EditorModel(image: image,
                                workingURL: FileManager.default.temporaryDirectory.appendingPathComponent("zoom.png"),
                                captureScale: 1)
        let canvas = CGSize(width: 400, height: 400)
        model.setCanvasSize(canvas)
        model.pointerOffset = CGSize(width: 0, height: -10)
        let imagePointUnderPointer: (EditorModel) -> CGFloat = { model in
            let fit = CanvasFit(pixelSize: model.pixelSize, captureScale: 1, zoom: model.zoom, pan: model.pan, in: canvas)
            return (canvas.height / 2 - 10 - fit.imageRect.minY) / fit.scale
        }
        let before = imagePointUnderPointer(model)
        for zoom in stride(from: 1.5, through: 8, by: 0.5) { model.setZoom(zoom, aroundPointer: true) }
        #expect(abs(imagePointUnderPointer(model) - before) < 0.01)
    }

    @Test func panningNeverOpensAGapAtAnEdge() {
        let image = NSImage(size: NSSize(width: 400, height: 400), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let model = EditorModel(image: image,
                                workingURL: FileManager.default.temporaryDirectory.appendingPathComponent("pan.png"),
                                captureScale: 1)
        model.setCanvasSize(CGSize(width: 400, height: 400))
        model.setZoom(2)
        model.panBy(dx: 5000, dy: -5000)
        #expect(model.pan == CGSize(width: 200, height: -200))
    }
}

@MainActor
struct RememberedSizeTests {
    @Test func resizingASelectedLineAlsoSetsTheWidthOfTheNextEditor() {
        func model() -> EditorModel {
            let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill(); return true
            }
            return EditorModel(image: image,
                               workingURL: FileManager.default.temporaryDirectory.appendingPathComponent("size.png"),
                               captureScale: 2)
        }
        let first = model()
        let before = first.lineWidth
        first.commitDraft(Annotation(kind: .line, start: .zero, end: CGPoint(x: 50, y: 50),
                                     color: .red, lineWidth: first.lineWidth, fontSize: 36))
        first.stepLineWidth(by: 1)
        #expect(first.annotations[0].lineWidth == before + 2)
        #expect(model().lineWidth == before + 2)
        first.stepLineWidth(by: -1)
    }
}
