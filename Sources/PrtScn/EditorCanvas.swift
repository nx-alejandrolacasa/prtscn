import SwiftUI

/// Maps between the capture's pixel space and on-screen view coordinates for an
/// aspect-fit image.
private struct CanvasFit {
    let imageRect: CGRect
    let scale: CGFloat

    init(pixelSize: CGSize, captureScale: CGFloat, in size: CGSize) {
        // Fit the image, but never enlarge past its native 1:1 size
        // (1 / captureScale view-points per pixel), so it always reads true-size.
        let scale = min(size.width / pixelSize.width, size.height / pixelSize.height, 1 / max(captureScale, 1))
        let drawn = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        self.scale = scale
        self.imageRect = CGRect(x: (size.width - drawn.width) / 2,
                                y: (size.height - drawn.height) / 2,
                                width: drawn.width, height: drawn.height)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * scale, y: imageRect.minY + p.y * scale)
    }

    func toImage(_ p: CGPoint, clampedTo pixelSize: CGSize) -> CGPoint {
        CGPoint(x: min(max((p.x - imageRect.minX) / scale, 0), pixelSize.width),
                y: min(max((p.y - imageRect.minY) / scale, 0), pixelSize.height))
    }
}

/// What the current drag is doing, decided on press.
private struct DragSession {
    enum Kind {
        case draw
        case placeText
        case placeCounter
        case finishingEdit
        case move(UUID)
        case resize(UUID, ResizeHandle)
        case pickColor
    }

    let kind: Kind
    let pressImage: CGPoint
    /// The annotation's endpoints at press, so move/resize stay anchored.
    var originalStart: CGPoint = .zero
    var originalEnd: CGPoint = .zero
    /// Fixed corner for a corner-resize (nil for arrow endpoints).
    var anchor: CGPoint?
    /// Set once the drag actually moves, so a plain click doesn't snapshot.
    var didMutate = false
}

/// What the current crop drag is doing.
private struct CropSession {
    enum Kind {
        case new
        case move
        case resize(ResizeHandle)
    }

    let kind: Kind
    let pressImage: CGPoint
    let originalRect: CGRect
    var anchor: CGPoint?
}

/// The editor's drawing surface: renders the capture, its annotations and the
/// selection handles; a drag gesture draws / selects / moves / resizes; a
/// double-click re-opens text for editing.
struct EditorCanvas: View {
    let model: EditorModel

    @FocusState private var textFieldFocused: Bool
    @State private var session: DragSession?
    @State private var cropSession: CropSession?

    /// Hit slop in view points.
    private let handleHitRadius: CGFloat = 11
    private let bodyTolerance: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let fit = CanvasFit(pixelSize: model.pixelSize, captureScale: model.captureScale, in: geo.size)

            ZStack(alignment: .topLeading) {
                canvas(fit: fit)
                    .gesture(drawGesture(fit: fit))
                    .simultaneousGesture(doubleClickGesture(fit: fit))
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard model.isPickingColor else { return }
                        switch phase {
                        case .active(let location):
                            // Re-assert every move: SwiftUI resets the cursor on
                            // each mouse-moved, so a one-shot set wouldn't stick.
                            NSCursor.crosshair.set()
                            model.updateHoverColor(at: fit.toImage(location, clampedTo: model.pixelSize))
                        case .ended:
                            NSCursor.arrow.set()
                            model.updateHoverColor(at: nil)
                        }
                    }
                textOverlay(fit: fit)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onDeleteCommand { model.deleteSelected() }
        }
        // Switching tools commits any in-progress text.
        .onChange(of: model.tool) { _, _ in
            if model.editingTextID != nil { model.finishTextEditing() }
        }
        // Restore the arrow the moment picking ends (a lingering crosshair would
        // otherwise stay until the next mouse move).
        .onChange(of: model.isPickingColor) { _, picking in
            if !picking { NSCursor.arrow.set() }
        }
    }

    // MARK: - Canvas

    private func canvas(fit: CanvasFit) -> some View {
        Canvas { context, _ in
            context.draw(Image(nsImage: model.baseImage), in: fit.imageRect)

            for annotation in model.annotations where annotation.id != model.editingTextID {
                draw(annotation, in: &context, fit: fit)
            }
            if let draft = model.draft {
                draw(draft, in: &context, fit: fit)
            }
            if model.isCropping {
                drawCropOverlay(in: &context, fit: fit)
            } else if let selected = model.selectedAnnotation, selected.id != model.editingTextID {
                drawSelection(selected, in: &context, fit: fit)
            }
        }
        .contentShape(Rectangle())
        // Marquee pointer while cropping. (The color picker uses NSCursor's
        // crosshair instead — see the hover handler — as SwiftUI's PointerStyle
        // has no crosshair.)
        .pointerStyle(model.isCropping ? .rectSelection : nil)
    }

    private func draw(_ annotation: Annotation, in context: inout GraphicsContext, fit: CanvasFit) {
        let width = annotation.lineWidth * fit.scale
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        let rect = CGRect(origin: fit.toView(annotation.boundingRect.origin),
                          size: CGSize(width: annotation.boundingRect.width * fit.scale,
                                       height: annotation.boundingRect.height * fit.scale))

        switch annotation.kind {
        case .arrow:
            let geometry = arrowGeometry(from: annotation.start, to: annotation.end,
                                         lineWidth: annotation.lineWidth)
            var path = Path()
            path.move(to: fit.toView(geometry.shaftStart))
            path.addLine(to: fit.toView(geometry.tip))
            path.move(to: fit.toView(geometry.leftBarb))
            path.addLine(to: fit.toView(geometry.tip))
            path.addLine(to: fit.toView(geometry.rightBarb))
            context.stroke(path, with: .color(annotation.color), style: style)
        case .line:
            var path = Path()
            path.move(to: fit.toView(annotation.start))
            path.addLine(to: fit.toView(annotation.end))
            context.stroke(path, with: .color(annotation.color), style: style)
        case .measure:
            let geometry = measureGeometry(from: annotation.start, to: annotation.end,
                                           lineWidth: annotation.lineWidth)
            var path = Path()
            path.move(to: fit.toView(geometry.start))
            path.addLine(to: fit.toView(geometry.end))
            path.move(to: fit.toView(geometry.startTickA))
            path.addLine(to: fit.toView(geometry.startTickB))
            path.move(to: fit.toView(geometry.endTickA))
            path.addLine(to: fit.toView(geometry.endTickB))
            context.stroke(path, with: .color(annotation.color), style: style)
            drawMeasureLabel(geometry, in: &context, fit: fit, color: annotation.color,
                             fontSize: annotation.fontSize, captureScale: model.captureScale)
        case .rectangle:
            context.stroke(Path(rect), with: .color(annotation.color), style: style)
        case .roundedRect:
            let radius = annotation.cornerRadius * fit.scale
            context.stroke(Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                           with: .color(annotation.color), style: style)
        case .ellipse:
            context.stroke(Path(ellipseIn: rect), with: .color(annotation.color), style: style)
        case .pixelate:
            if let mosaic = model.pixelatedRegion(annotation.boundingRect) {
                context.draw(Image(decorative: mosaic, scale: 1), in: rect)
            } else {
                context.fill(Path(rect), with: .color(.gray))
            }
        case .counter:
            let center = fit.toView(annotation.start)
            let radius = annotation.counterRadius * fit.scale
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2)),
                         with: .color(annotation.color))
            let number = Text("\(annotation.number)")
                .font(.system(size: annotation.fontSize * fit.scale, weight: .bold))
                .foregroundStyle(.white)
            context.draw(number, at: center, anchor: .center)
        case .text:
            let text = Text(annotation.text)
                .font(.system(size: annotation.fontSize * fit.scale, weight: .semibold,
                              design: annotation.fontDesign.swiftUIDesign))
                .foregroundStyle(annotation.color)
            context.draw(text, at: fit.toView(annotation.start), anchor: .topLeading)
        }
    }

    /// The measure tool's pixel-count label: white text on a rounded pill in
    /// the annotation color, centered on the line's midpoint. Reported in
    /// logical points (`geometry.length / captureScale`) — the unit a design
    /// spec or eyeballed estimate uses — and stays correct no matter how
    /// zoomed-out the on-screen canvas is, since it comes from the capture's
    /// pixel space, not the view.
    private func drawMeasureLabel(_ geometry: MeasureGeometry, in context: inout GraphicsContext,
                                  fit: CanvasFit, color: Color, fontSize: CGFloat, captureScale: CGFloat) {
        // Built as a plain String first: interpolating an Int directly inside
        // a Text("...") literal routes through LocalizedStringKey, which
        // applies locale thousands-grouping (e.g. "1.152" on a Spanish
        // locale) — not what we want for a raw measurement.
        let label: String = "\(Int((geometry.length / captureScale).rounded())) px"
        let text = Text(label)
            .font(.system(size: fontSize * fit.scale, weight: .semibold))
            .foregroundStyle(.white)
        let resolved = context.resolve(text)
        let huge = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = resolved.measure(in: huge)
        let center = fit.toView(geometry.mid)
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 3
        let pillWidth = size.width + paddingX * 2
        let pillHeight = size.height + paddingY * 2
        let pillOrigin = CGPoint(x: center.x - pillWidth / 2, y: center.y - pillHeight / 2)
        let pillRect = CGRect(origin: pillOrigin, size: CGSize(width: pillWidth, height: pillHeight))
        context.fill(Path(roundedRect: pillRect, cornerRadius: pillHeight / 2), with: .color(color))
        context.draw(text, at: center, anchor: .center)
    }

    /// Draws the selection affordances: a thin outline for text (no handles) and
    /// blue dots at each resize/endpoint handle.
    private func drawSelection(_ annotation: Annotation, in context: inout GraphicsContext, fit: CanvasFit) {
        if annotation.kind == .text {
            let r = CGRect(origin: fit.toView(annotation.textRect.origin),
                           size: CGSize(width: annotation.textRect.width * fit.scale,
                                        height: annotation.textRect.height * fit.scale))
                .insetBy(dx: -4, dy: -2)
            context.stroke(Path(roundedRect: r, cornerRadius: 4),
                           with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1))
        }
        if annotation.kind == .counter {
            let center = fit.toView(annotation.start)
            let radius = annotation.counterRadius * fit.scale + 3
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2)),
                           with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5))
        }
        for handle in annotation.handles {
            let center = fit.toView(handle.point)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)),
                         with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(.accentColor))
        }
    }

    // MARK: - Drag: draw / select / move / resize

    private func drawGesture(fit: CanvasFit) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if model.isCropping { cropChanged(value, fit: fit); return }
                if session == nil { session = makeSession(pressView: value.startLocation, fit: fit) }
                guard var current = session else { return }

                let moved = hypot(value.location.x - value.startLocation.x,
                                  value.location.y - value.startLocation.y) > 2
                let image = fit.toImage(value.location, clampedTo: model.pixelSize)

                switch current.kind {
                case .draw:
                    let labelSize = model.tool == .measure ? model.measureSize : model.fontSize
                    model.draft = Annotation(kind: model.tool, start: current.pressImage, end: image,
                                             color: model.color, lineWidth: model.lineWidth,
                                             fontSize: labelSize)
                case .move(let id):
                    guard moved else { return }
                    if !current.didMutate { model.snapshot(); current.didMutate = true; session = current }
                    let dx = image.x - current.pressImage.x, dy = image.y - current.pressImage.y
                    model.setPoints(id: id,
                                    start: CGPoint(x: current.originalStart.x + dx, y: current.originalStart.y + dy),
                                    end: CGPoint(x: current.originalEnd.x + dx, y: current.originalEnd.y + dy))
                case .resize(let id, let handle):
                    guard moved else { return }
                    if !current.didMutate { model.snapshot(); current.didMutate = true; session = current }
                    switch handle {
                    case .start: model.setPoints(id: id, start: image, end: current.originalEnd)
                    case .end: model.setPoints(id: id, start: current.originalStart, end: image)
                    default: model.setPoints(id: id, start: current.anchor ?? current.originalStart, end: image)
                    }
                case .placeText, .placeCounter, .finishingEdit, .pickColor:
                    break
                }
            }
            .onEnded { value in
                if model.isCropping {
                    // Discard a too-small drag so we stay in the "draw a region" phase.
                    if let r = model.cropRect, r.width < 8 || r.height < 8 { model.cropRect = nil }
                    cropSession = nil
                    return
                }
                defer { session = nil }
                guard let current = session else { return }
                switch current.kind {
                case .draw:
                    if let draft = model.draft, draft.isMeaningful { model.commitDraft(draft) }
                    model.draft = nil
                case .placeText:
                    model.beginText(at: current.pressImage)
                case .placeCounter:
                    model.stampCounter(at: current.pressImage)
                case .finishingEdit:
                    model.finishTextEditing()
                case .pickColor:
                    model.commitPickedColor()
                case .move, .resize:
                    break
                }
            }
    }

    /// Decides, on press, what this drag will do.
    private func makeSession(pressView: CGPoint, fit: CanvasFit) -> DragSession {
        let pressImage = fit.toImage(pressView, clampedTo: model.pixelSize)

        // Picking mode takes over every click on the canvas until it commits
        // or is cancelled — it doesn't select/move/draw annotations.
        if model.isPickingColor {
            return DragSession(kind: .pickColor, pressImage: pressImage)
        }

        // A press while editing text just commits it.
        if model.editingTextID != nil {
            return DragSession(kind: .finishingEdit, pressImage: pressImage)
        }

        // 1. A handle of the currently selected annotation.
        if let selected = model.selectedAnnotation {
            for handle in selected.handles where distance(pressView, fit.toView(handle.point)) <= handleHitRadius {
                return DragSession(kind: .resize(selected.id, handle.handle), pressImage: pressImage,
                                   originalStart: selected.start, originalEnd: selected.end,
                                   anchor: selected.anchor(for: handle.handle))
            }
        }

        // 2. The body of any annotation (topmost = last drawn) — select + move.
        let tolerance = bodyTolerance / fit.scale
        if let hit = model.annotations.last(where: { $0.bodyContains(pressImage, tolerance: tolerance) }) {
            model.selectedID = hit.id
            return DragSession(kind: .move(hit.id), pressImage: pressImage,
                               originalStart: hit.start, originalEnd: hit.end)
        }

        // 3. Empty space — deselect, then draw / place text / stamp a counter.
        model.selectedID = nil
        let kind: DragSession.Kind
        switch model.tool {
        case .text: kind = .placeText
        case .counter: kind = .placeCounter
        default: kind = .draw
        }
        return DragSession(kind: kind, pressImage: pressImage)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Double-click: edit text

    private func doubleClickGesture(fit: CanvasFit) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                guard !model.isCropping else { return }
                let point = fit.toImage(value.location, clampedTo: model.pixelSize)
                let tolerance = bodyTolerance / fit.scale
                if let hit = model.annotations.last(where: {
                    $0.kind == .text && $0.bodyContains(point, tolerance: tolerance)
                }) {
                    model.editText(id: hit.id)
                }
            }
    }

    // MARK: - Crop

    private func cropChanged(_ value: DragGesture.Value, fit: CanvasFit) {
        if cropSession == nil { cropSession = makeCropSession(pressView: value.startLocation, fit: fit) }
        guard let session = cropSession else { return }
        let moved = hypot(value.location.x - value.startLocation.x,
                          value.location.y - value.startLocation.y) > 2
        let current = fit.toImage(value.location, clampedTo: model.pixelSize)

        switch session.kind {
        case .new:
            model.cropRect = rect(from: session.pressImage, to: current)
        case .move:
            guard moved else { return }
            model.cropRect = movedRect(session.originalRect,
                                       dx: current.x - session.pressImage.x,
                                       dy: current.y - session.pressImage.y)
        case .resize:
            guard moved, let anchor = session.anchor else { return }
            model.cropRect = rect(from: anchor, to: current)
        }
    }

    private func makeCropSession(pressView: CGPoint, fit: CanvasFit) -> CropSession {
        let pressImage = fit.toImage(pressView, clampedTo: model.pixelSize)
        // No region yet (or the press is outside it): start drawing a new one.
        guard let rect = model.cropRect else {
            return CropSession(kind: .new, pressImage: pressImage, originalRect: .zero)
        }
        for corner in cropCorners(rect)
        where distance(pressView, fit.toView(corner.point)) <= handleHitRadius {
            return CropSession(kind: .resize(corner.handle), pressImage: pressImage,
                               originalRect: rect, anchor: oppositeCorner(corner.handle, in: rect))
        }
        if rect.contains(pressImage) {
            return CropSession(kind: .move, pressImage: pressImage, originalRect: rect)
        }
        return CropSession(kind: .new, pressImage: pressImage, originalRect: rect)
    }

    /// Normalized rect between two points (both already clamped to the image).
    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Offsets a rect, keeping it fully inside the image.
    private func movedRect(_ r: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let x = min(max(r.minX + dx, 0), model.pixelSize.width - r.width)
        let y = min(max(r.minY + dy, 0), model.pixelSize.height - r.height)
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    private func cropCorners(_ r: CGRect) -> [(handle: ResizeHandle, point: CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
    }

    private func oppositeCorner(_ handle: ResizeHandle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.maxX, y: r.minY)
        default: return CGPoint(x: r.minX, y: r.minY)
        }
    }

    private func drawCropOverlay(in context: inout GraphicsContext, fit: CanvasFit) {
        let image = fit.imageRect
        // Drawing phase: no region yet — dim the whole image a touch.
        guard let cropImageRect = model.cropRect else {
            context.fill(Path(image), with: .color(.black.opacity(0.25)))
            return
        }
        let crop = CGRect(origin: fit.toView(cropImageRect.origin),
                          size: CGSize(width: cropImageRect.width * fit.scale,
                                       height: cropImageRect.height * fit.scale))
        let dim = GraphicsContext.Shading.color(.black.opacity(0.45))
        context.fill(Path(CGRect(x: image.minX, y: image.minY, width: image.width, height: crop.minY - image.minY)), with: dim)
        context.fill(Path(CGRect(x: image.minX, y: crop.maxY, width: image.width, height: image.maxY - crop.maxY)), with: dim)
        context.fill(Path(CGRect(x: image.minX, y: crop.minY, width: crop.minX - image.minX, height: crop.height)), with: dim)
        context.fill(Path(CGRect(x: crop.maxX, y: crop.minY, width: image.maxX - crop.maxX, height: crop.height)), with: dim)

        context.stroke(Path(crop), with: .color(.white), style: StrokeStyle(lineWidth: 1.5))

        for corner in cropCorners(cropImageRect) {
            let center = fit.toView(corner.point)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)),
                         with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(.accentColor))
        }
    }

    // MARK: - Text overlay

    @ViewBuilder
    private func textOverlay(fit: CanvasFit) -> some View {
        if let id = model.editingTextID,
           let annotation = model.annotations.first(where: { $0.id == id }) {
            let origin = fit.toView(annotation.start)
            let font = Font.system(size: annotation.fontSize * fit.scale, weight: .semibold,
                                   design: annotation.fontDesign.swiftUIDesign)
            TextField("", text: Binding(get: { model.editingText }, set: { model.setEditingText($0) }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(annotation.color)
                // SwiftUI forces the system gray on a TextField prompt, so draw
                // our own placeholder in the drawing color instead.
                .overlay(alignment: .topLeading) {
                    if model.editingText.isEmpty {
                        Text("Text")
                            .font(font)
                            .foregroundStyle(annotation.color.opacity(0.7))
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: max(fit.imageRect.maxX - origin.x, 80), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .focused($textFieldFocused)
                .offset(x: origin.x, y: origin.y)
                // Focus once the field is actually in the hierarchy.
                .task(id: id) { textFieldFocused = true }
                .onSubmit { model.finishTextEditing() }
                .onExitCommand { model.finishTextEditing() }   // Esc
                .onChange(of: textFieldFocused) { _, focused in
                    // The placing click (and palette taps) steal first responder
                    // from the just-shown field. While still editing, reclaim it
                    // rather than committing — commits happen via Esc, clicking
                    // away on the canvas, or switching tools.
                    guard !focused, model.editingTextID == id else { return }
                    Task { @MainActor in
                        if model.editingTextID == id { textFieldFocused = true }
                    }
                }
        }
    }
}
