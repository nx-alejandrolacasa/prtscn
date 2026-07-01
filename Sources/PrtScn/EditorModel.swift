import AppKit
import Observation
import SwiftUI

/// Observable state + behavior for the in-app screenshot editor.
///
/// Annotations are kept non-destructively as `[Annotation]` in the capture's
/// pixel space; Copy / Save flatten them over `baseImage` via Core Graphics
/// (`prepareExport`), reusing `ScreenshotService`'s URL-based pipeline. OCR
/// always runs on the original capture, not the annotated result.
@MainActor
@Observable
final class EditorModel {
    /// The current capture, kept in memory as the drawing base and for OCR.
    /// Replaced when a crop is applied.
    private(set) var baseImage: NSImage

    /// A temp PNG this editor owns. Flattened exports are written here; cleaned
    /// up on close.
    let workingURL: URL

    /// The capture's true pixel dimensions — the annotation coordinate space.
    /// Shrinks when a crop is applied.
    private(set) var pixelSize: CGSize

    /// Backing scale of the capture: pixels ÷ this = logical points (1:1 size).
    /// Used to display the image at native size and to show sizes in points.
    let captureScale: CGFloat

    /// Called after the image geometry changes (a crop) so the controller can
    /// resize the window to fit.
    var onGeometryChange: (() -> Void)?

    // MARK: - Crop

    /// Whether the crop tool is active.
    var isCropping = false
    /// The pending crop region (pixel coords) while `isCropping`. `nil` means the
    /// user hasn't drawn a region yet (the "aim and drag" phase).
    var cropRect: CGRect?

    // MARK: - Drawing state

    var tool: EditTool = .arrow
    /// Drawing color and text font design — remembered across sessions via
    /// `SettingsStore`.
    var color: Color {
        didSet { SettingsStore.shared.editorColor = color }
    }
    var fontDesign: FontDesign {
        didSet { SettingsStore.shared.editorFontDesign = fontDesign }
    }
    /// Default stroke / font sizes, scaled to the capture so they read the same
    /// regardless of resolution.
    var lineWidth: CGFloat
    /// Text size and step-counter size are tracked independently.
    var fontSize: CGFloat
    var counterSize: CGFloat
    /// The measure tool's pixel-count label size — independent of `fontSize`
    /// so resizing it doesn't also resize the text tool's default.
    var measureSize: CGFloat
    /// The next step-counter badge number to stamp.
    var nextCounter: Int = 1

    /// True while the eyedropper (title-bar toolbar) is active: hovering the
    /// capture live-previews the sampled pixel's color, a click copies its hex
    /// and exits. Independent of `tool` — it samples *from* the capture, it
    /// doesn't feed the drawing palette.
    var isPickingColor = false
    var hoverColor: Color?
    var hoverColorHex: String?

    /// Committed annotations, oldest first.
    private(set) var annotations: [Annotation] = []
    /// The shape currently being dragged out (not yet committed).
    var draft: Annotation?
    /// The currently selected annotation, if any.
    var selectedID: UUID?
    /// The text annotation being edited, if any.
    var editingTextID: UUID?
    private var editingIsNew = false

    /// Snapshot-based undo: each entry is the full annotation list as it was
    /// *before* a change, so moves, resizes, deletes and draws all undo alike.
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    /// Transient confirmation shown after an action ("Copied", "Saved").
    var statusMessage: String?

    var onClose: (() -> Void)?
    private var closed = false

    init(image: NSImage, workingURL: URL, captureScale: CGFloat) {
        self.baseImage = image
        self.workingURL = workingURL
        self.captureScale = max(captureScale, 1)
        self.color = SettingsStore.shared.editorColor
        self.fontDesign = SettingsStore.shared.editorFontDesign
        let px = Self.pixelSize(of: image)
        self.pixelSize = px
        // Stored in pixel space (annotations render with them); shown in points.
        // Sized off the capture's backing scale (retina vs. not), not its content
        // dimensions — a small window shot and a huge multi-monitor shot taken on
        // the same display should get the same default thickness.
        self.lineWidth = 3 * self.captureScale
        self.fontSize = 18 * self.captureScale
        self.counterSize = 21 * self.captureScale
        self.measureSize = 18 * self.captureScale
    }

    /// A pixel size shown to the user as logical points.
    func inPoints(_ pixels: CGFloat) -> Int { Int((pixels / captureScale).rounded()) }

    // MARK: - Annotation editing

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedAnnotation: Annotation? {
        annotations.first { $0.id == selectedID }
    }

    /// Records the current state for undo. Call once, before a logical change.
    func snapshot() {
        undoStack.append(annotations)
        redoStack.removeAll()
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    func undo() {
        finishTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        clearSelectionIfMissing()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        clearSelectionIfMissing()
    }

    private func clearSelectionIfMissing() {
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    /// Commits a freshly drawn shape and selects it.
    func commitDraft(_ annotation: Annotation) {
        snapshot()
        annotations.append(annotation)
        selectedID = annotation.id
    }

    /// Updates an annotation's endpoints (live move/resize). The caller takes
    /// the undo `snapshot()` once, when the drag first moves.
    func setPoints(id: UUID, start: CGPoint, end: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].start = start
        annotations[index].end = end
    }

    /// Duplicates the selected annotation, offset slightly so the copy is
    /// visible, and selects it (so ⌘D again keeps cascading). A duplicated step
    /// counter takes the next sequential number rather than repeating the badge.
    func duplicateSelected() {
        finishTextEditing()
        guard let original = selectedAnnotation else { return }
        snapshot()
        let offset = 16 * captureScale
        var copy = original.duplicated(offsetBy: CGPoint(x: offset, y: offset))
        if copy.kind == .counter {
            copy.number = nextCounter
            nextCounter += 1
        }
        annotations.append(copy)
        selectedID = copy.id
    }

    func deleteSelected() {
        guard let id = selectedID, annotations.contains(where: { $0.id == id }) else { return }
        snapshot()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    // MARK: - Crop

    func beginCrop() {
        finishTextEditing()
        selectedID = nil
        cropRect = nil
        isCropping = true
    }

    func cancelCrop() {
        isCropping = false
        cropRect = nil
    }

    /// Crops the capture to `cropRect`: replaces the base image, shifts every
    /// annotation into the new coordinate space, and asks the window to resize.
    func applyCrop() {
        guard let rect = cropRect?.integral, rect.width >= 1, rect.height >= 1,
              let base = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = base.cropping(to: rect) else { return }
        isCropping = false
        cropRect = nil

        annotations = annotations.map { annotation in
            var moved = annotation
            moved.start = CGPoint(x: annotation.start.x - rect.minX, y: annotation.start.y - rect.minY)
            moved.end = CGPoint(x: annotation.end.x - rect.minX, y: annotation.end.y - rect.minY)
            return moved
        }
        // A crop is a structural change, so it isn't part of the annotation undo
        // history; clear it to avoid restoring coordinates from the old space.
        undoStack.removeAll()
        redoStack.removeAll()

        baseImage = NSImage(cgImage: cropped, size: rect.size)
        pixelSize = rect.size
        selectedID = nil
        onGeometryChange?()
    }

    // MARK: - Text

    /// Places a new text annotation at `point` and starts editing it.
    func beginText(at point: CGPoint) {
        finishTextEditing()
        snapshot()
        let annotation = Annotation(kind: .text, start: point, end: point,
                                    color: color, lineWidth: 0, fontSize: fontSize,
                                    fontDesign: fontDesign)
        annotations.append(annotation)
        selectedID = annotation.id
        editingTextID = annotation.id
        editingIsNew = true
    }

    // MARK: - Text style

    /// Multiplies the current text size and applies it to the selected/edited
    /// text if any.
    func adjustFontSize(by factor: CGFloat) {
        fontSize = clampSize(fontSize * factor)
        applyTextStyleToSelection()
    }

    /// Multiplies the current step-counter size and applies it to a selected
    /// counter if any.
    func adjustCounterSize(by factor: CGFloat) {
        counterSize = clampSize(counterSize * factor)
        applyStyle(to: .counter) { $0.fontSize = self.counterSize }
    }

    /// Multiplies the current measure-label size and applies it to a selected
    /// measure line if any.
    func adjustMeasureSize(by factor: CGFloat) {
        measureSize = clampSize(measureSize * factor)
        applyStyle(to: .measure) { $0.fontSize = self.measureSize }
    }

    func setFontDesign(_ design: FontDesign) {
        fontDesign = design
        applyTextStyleToSelection()
    }

    private func clampSize(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), max(6 * captureScale, 10)), pixelSize.height * 0.5)
    }

    /// Pushes the current size/design onto the selected (or actively edited)
    /// text annotation, so changes are visible immediately.
    private func applyTextStyleToSelection() {
        applyStyle(to: .text) {
            $0.fontSize = self.fontSize
            $0.fontDesign = self.fontDesign
        }
    }

    /// Applies `mutate` to the selected annotation if it's of `kind`.
    private func applyStyle(to kind: EditTool, _ mutate: (inout Annotation) -> Void) {
        guard let id = editingTextID ?? selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].kind == kind else { return }
        snapshot()
        mutate(&annotations[index])
    }

    /// Stamps the next sequential numbered badge at `point` and advances.
    func stampCounter(at point: CGPoint) {
        snapshot()
        let annotation = Annotation(kind: .counter, start: point, end: point,
                                    color: color, lineWidth: 0, fontSize: counterSize, number: nextCounter)
        annotations.append(annotation)
        selectedID = annotation.id
        nextCounter += 1
    }

    /// Re-opens an existing text annotation for editing (double-click).
    func editText(id: UUID) {
        finishTextEditing()
        guard annotations.contains(where: { $0.id == id }) else { return }
        snapshot()
        selectedID = id
        editingTextID = id
        editingIsNew = false
    }

    func setEditingText(_ string: String) {
        guard let id = editingTextID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].text = string
    }

    var editingText: String {
        guard let id = editingTextID else { return "" }
        return annotations.first(where: { $0.id == id })?.text ?? ""
    }

    /// Ends text editing, discarding an empty box. If that box was a brand-new
    /// placement, the undo snapshot is dropped too so undo isn't a no-op.
    func finishTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        let wasNew = editingIsNew
        editingIsNew = false
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if !annotations[index].isMeaningful {
            annotations.remove(at: index)
            if wasNew, !undoStack.isEmpty { undoStack.removeLast() }
            if selectedID == id { selectedID = nil }
        }
    }

    // MARK: - Actions (reuse ScreenshotService)

    func copy() {
        finishTextEditing()
        prepareExport()
        ScreenshotService.shared.copyToClipboard(workingURL)
        completed("Copied")
    }

    func save() {
        finishTextEditing()
        prepareExport()
        if ScreenshotService.shared.save(workingURL) != nil { completed("Saved") }
    }

    func copyText() {
        ScreenshotService.shared.copyText(in: baseImage)
        completed("Text copied")
    }

    /// Enters eyedropper picking mode: the canvas starts live-previewing the
    /// hovered pixel's color (see `updateHoverColor`) until a click commits it
    /// or Escape cancels.
    func beginPickingColor() {
        isPickingColor = true
        hoverColor = nil
        hoverColorHex = nil
    }

    func cancelPickingColor() {
        isPickingColor = false
        hoverColor = nil
        hoverColorHex = nil
    }

    /// Called continuously while hovering the capture in picking mode; `pixel`
    /// is `nil` once the cursor leaves the image.
    func updateHoverColor(at pixel: CGPoint?) {
        guard let pixel, let sampled = colorAt(pixel: pixel) else {
            hoverColor = nil
            hoverColorHex = nil
            return
        }
        hoverColor = Color(sampled)
        hoverColorHex = Self.hex(sampled)
    }

    /// Copies the currently hovered color's hex to the clipboard and exits
    /// picking mode. A no-op if the cursor wasn't over the image on click.
    func commitPickedColor() {
        defer { cancelPickingColor() }
        guard let hex = hoverColorHex else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        flash(hex)
    }

    /// Samples the base image at a pixel coordinate (top-left origin, matching
    /// the annotation pixel space) — not the canvas's rendered annotations, so
    /// this reads the capture's real content regardless of what's drawn atop it.
    private func colorAt(pixel: CGPoint) -> NSColor? {
        guard let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let x = Int(pixel.x), y = Int(pixel.y)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    /// A mosaic of `rect` (pixel coords) from the base image: downscale, then
    /// nearest-neighbor upscale — pure Core Graphics, no Metal. Used for the
    /// pixelate tool on screen and in the export.
    func pixelatedRegion(_ rect: CGRect) -> CGImage? {
        guard let base = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let region = rect.integral.intersection(bounds)
        guard region.width >= 1, region.height >= 1, let sub = base.cropping(to: region) else { return nil }

        let block = max(min(pixelSize.width, pixelSize.height) * 0.02, 6)
        let smallWidth = max(Int(region.width / block), 1)
        let smallHeight = max(Int(region.height / block), 1)
        guard let small = Self.resize(sub, width: smallWidth, height: smallHeight, interpolation: .medium)
        else { return nil }
        return Self.resize(small, width: Int(region.width), height: Int(region.height), interpolation: .none)
    }

    private static func resize(_ image: CGImage, width: Int, height: Int,
                               interpolation: CGInterpolationQuality) -> CGImage? {
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A share-sheet item for the flattened capture: a nicely-named PNG file
    /// wrapped so the sheet shows a thumbnail, title, and app icon in its header.
    func sharingItem() -> NSPreviewRepresentingActivityItem {
        prepareExport()
        let thumbnail = NSImage(contentsOf: workingURL) ?? baseImage

        // A friendly-named copy so share targets get a sensible filename.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrtScn \(Self.shareTimestamp()).png")
        try? FileManager.default.removeItem(at: url)
        let shared = (try? FileManager.default.copyItem(at: workingURL, to: url)) != nil ? url : workingURL

        return NSPreviewRepresentingActivityItem(
            item: shared,
            title: shared.deletingPathExtension().lastPathComponent,
            image: thumbnail,
            icon: NSApp.applicationIconImage)
    }

    private static func shareTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// Finishes an action: closes the editor or shows a confirmation, per the
    /// user's "close editor after action" preference.
    private func completed(_ message: String) {
        if SettingsStore.shared.closeEditorAfterAction {
            close()
        } else {
            flash(message)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        ScreenshotService.shared.cleanup(workingURL)
        onClose?()
    }

    // MARK: - Export

    /// Flattens the annotation layer over the capture and overwrites the working
    /// PNG. Always re-renders from `baseImage`, so it stays correct even after
    /// undoing every annotation.
    private func prepareExport() {
        // No side effects here — this is reachable from the share item's
        // validation. Committing text is done by the Copy/Save actions instead.
        guard let cgImage = renderFlattened(),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: workingURL)
    }

    /// Composites the base capture + annotations at full pixel resolution.
    /// Core Graphics uses a bottom-left origin, so annotation y-coordinates
    /// (stored top-left) are flipped via `flip(_:)`.
    private func renderFlattened() -> CGImage? {
        guard let base = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = base.width, height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let h = CGFloat(height)
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }

        for annotation in annotations where annotation.isMeaningful {
            let stroke = NSColor(annotation.color).cgColor
            context.setStrokeColor(stroke)
            context.setFillColor(stroke)
            context.setLineWidth(annotation.lineWidth)

            switch annotation.kind {
            case .arrow:
                let geometry = arrowGeometry(from: annotation.start, to: annotation.end,
                                             lineWidth: annotation.lineWidth)
                context.beginPath()
                context.move(to: flip(geometry.shaftStart))
                context.addLine(to: flip(geometry.tip))
                context.strokePath()
                context.beginPath()
                context.addLines(between: [geometry.leftBarb, geometry.tip, geometry.rightBarb].map(flip))
                context.strokePath()
            case .line:
                context.beginPath()
                context.move(to: flip(annotation.start))
                context.addLine(to: flip(annotation.end))
                context.strokePath()
            case .measure:
                let geometry = measureGeometry(from: annotation.start, to: annotation.end,
                                               lineWidth: annotation.lineWidth)
                context.beginPath()
                context.move(to: flip(geometry.start))
                context.addLine(to: flip(geometry.end))
                context.move(to: flip(geometry.startTickA))
                context.addLine(to: flip(geometry.startTickB))
                context.move(to: flip(geometry.endTickA))
                context.addLine(to: flip(geometry.endTickB))
                context.strokePath()
                drawMeasureLabel(geometry, color: annotation.color, fontSize: annotation.fontSize,
                                 in: context, imageHeight: h)
            case .rectangle:
                context.stroke(flippedRect(annotation.boundingRect, in: h))
            case .roundedRect:
                let path = CGPath(roundedRect: flippedRect(annotation.boundingRect, in: h),
                                  cornerWidth: annotation.cornerRadius,
                                  cornerHeight: annotation.cornerRadius, transform: nil)
                context.addPath(path)
                context.strokePath()
            case .ellipse:
                context.strokeEllipse(in: flippedRect(annotation.boundingRect, in: h))
            case .pixelate:
                if let mosaic = pixelatedRegion(annotation.boundingRect) {
                    context.draw(mosaic, in: flippedRect(annotation.boundingRect, in: h))
                }
            case .counter:
                drawCounter(annotation, in: context, imageHeight: h)
            case .text:
                drawText(annotation, in: context, imageHeight: h)
            }
        }
        return context.makeImage()
    }

    /// A filled circle in the annotation color with the white step number,
    /// centered at `start`.
    private func drawCounter(_ annotation: Annotation, in context: CGContext, imageHeight: CGFloat) {
        let center = CGPoint(x: annotation.start.x, y: imageHeight - annotation.start.y)
        let radius = annotation.counterRadius
        context.setFillColor(NSColor(annotation.color).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))

        let string = NSAttributedString(string: "\(annotation.number)", attributes: [
            .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        guard size.width > 0, size.height > 0 else { return }
        let label = NSImage(size: size)
        label.lockFocus()
        string.draw(at: .zero)
        label.unlockFocus()
        guard let labelImage = label.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.draw(labelImage, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                            width: size.width, height: size.height))
    }

    /// The measure tool's pixel-count label, mirroring `EditorCanvas`'s on-screen
    /// rendering: white text on a rounded pill in the annotation color, centered
    /// on the line's midpoint. Reported in logical points (`geometry.length /
    /// captureScale`), matching the on-screen label.
    private func drawMeasureLabel(_ geometry: MeasureGeometry, color: Color, fontSize: CGFloat,
                                  in context: CGContext, imageHeight: CGFloat) {
        let center = CGPoint(x: geometry.mid.x, y: imageHeight - geometry.mid.y)
        let string = NSAttributedString(string: "\(Int((geometry.length / captureScale).rounded())) px", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        guard size.width > 0, size.height > 0 else { return }

        let paddingX: CGFloat = fontSize * 0.35
        let paddingY: CGFloat = fontSize * 0.18
        let pillSize = CGSize(width: size.width + paddingX * 2, height: size.height + paddingY * 2)
        let pillRect = CGRect(x: center.x - pillSize.width / 2, y: center.y - pillSize.height / 2,
                              width: pillSize.width, height: pillSize.height)
        context.setFillColor(NSColor(color).cgColor)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillSize.height / 2,
                              cornerHeight: pillSize.height / 2, transform: nil)
        context.addPath(pillPath)
        context.fillPath()

        let label = NSImage(size: size)
        label.lockFocus()
        string.draw(at: .zero)
        label.unlockFocus()
        guard let labelImage = label.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.draw(labelImage, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                            width: size.width, height: size.height))
    }

    private func flippedRect(_ rect: CGRect, in height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Text is rendered to a small image (so we don't fight Core Graphics' text
    /// matrix) and drawn upright at the annotation's top-left.
    private func drawText(_ annotation: Annotation, in context: CGContext, imageHeight: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: annotationNSFont(size: annotation.fontSize, design: annotation.fontDesign),
            .foregroundColor: NSColor(annotation.color),
        ]
        let string = NSAttributedString(string: annotation.text, attributes: attributes)
        let size = string.size()
        guard size.width > 0, size.height > 0 else { return }

        let label = NSImage(size: size)
        label.lockFocus()
        string.draw(at: .zero)
        label.unlockFocus()
        guard let labelImage = label.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let rect = CGRect(x: annotation.start.x,
                          y: imageHeight - annotation.start.y - size.height,
                          width: size.width, height: size.height)
        context.draw(labelImage, in: rect)
    }

    private func flash(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if statusMessage == message { statusMessage = nil }
        }
    }

    /// The capture's real pixel dimensions, independent of DPI metadata.
    private static func pixelSize(of image: NSImage) -> CGSize {
        var width = 0, height = 0
        for rep in image.representations {
            width = max(width, rep.pixelsWide)
            height = max(height, rep.pixelsHigh)
        }
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : image.size
    }
}
