import SwiftUI

/// Maps between the capture's pixel space and on-screen view coordinates.
///
/// The canvas spans the window's whole content area; `insets` describe the
/// frame margins (and the palette band) the *fitted* image sits within. As
/// `zoom` grows, the image expands out of that framed area — its boundaries
/// move into the margins and eventually bleed edge-to-edge — rather than
/// magnifying inside a fixed rectangle.
struct CanvasFit {
    let imageRect: CGRect
    let scale: CGFloat

    /// The aspect-fit scale at zoom 1: fit the canvas, but never enlarge past
    /// the image's native 1:1 size (1 / captureScale view-points per pixel),
    /// so it always reads true-size.
    static func baseScale(pixelSize: CGSize, captureScale: CGFloat,
                          in size: CGSize) -> CGFloat {
        let available = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        return min(available.width / pixelSize.width, available.height / pixelSize.height,
                   1 / max(captureScale, 1))
    }

    /// Center of the canvas — the point the image grows around.
    private static func anchor(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Pan clamped per axis: while the image fits in the window it stays fully
    /// visible; once it overflows, no gap may open at an edge. Shared with
    /// `EditorModel` so the stored pan never drifts off what can be shown.
    static func clampedPan(drawn: CGSize, pan: CGSize, in size: CGSize) -> CGSize {
        let anchor = anchor(in: size)
        func clamp(_ pan: CGFloat, anchor: CGFloat, drawn: CGFloat, full: CGFloat) -> CGFloat {
            let origin = anchor - drawn / 2 + pan
            let clamped = min(max(origin, min(0, full - drawn)), max(0, full - drawn))
            return pan + (clamped - origin)
        }
        return CGSize(width: clamp(pan.width, anchor: anchor.x, drawn: drawn.width, full: size.width),
                      height: clamp(pan.height, anchor: anchor.y, drawn: drawn.height, full: size.height))
    }

    init(pixelSize: CGSize, captureScale: CGFloat, zoom: CGFloat, pan: CGSize,
         in size: CGSize) {
        let scale = Self.baseScale(pixelSize: pixelSize, captureScale: captureScale,
                                   in: size) * zoom
        let drawn = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let anchor = Self.anchor(in: size)
        let pan = Self.clampedPan(drawn: drawn, pan: pan, in: size)
        self.scale = scale
        self.imageRect = CGRect(x: anchor.x - drawn.width / 2 + pan.width,
                                y: anchor.y - drawn.height / 2 + pan.height,
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
        /// A press on empty space with the move tool, or a shift/⌘-click that
        /// only toggled the selection — nothing to drag.
        case idle
        /// A select-tool drag on empty space — rubber-band selection.
        case marquee
        case placeText
        case placeCounter
        case finishingEdit
        case move(UUID)
        case resize(UUID, ResizeHandle)
        case pickColor
    }

    let kind: Kind
    let pressImage: CGPoint
    /// The shape side the line's start snapped to at press, if any.
    var startBinding: ShapeBinding?
    /// The annotation's endpoints at press, so move/resize stay anchored.
    var originalStart: CGPoint = .zero
    var originalEnd: CGPoint = .zero
    /// Every selected annotation's endpoints at press when a `.move` drags a
    /// multi-selection — the whole group translates together.
    var groupOriginals: [UUID: (start: CGPoint, end: CGPoint)] = [:]
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
    /// The zoom level when a pinch began; the gesture's magnification is
    /// relative to it, so consecutive pinches compound naturally.
    @State private var pinchBaseZoom: CGFloat?
    /// The measure endpoint being dragged (image coords, snapped) — a magnifier
    /// loupe follows it for pixel-precise placement. `nil` when not dragging.
    @State private var loupePoint: CGPoint?
    /// The hovered point (image coords, snapped) while the measure tool is
    /// armed but not yet dragging — the loupe shows here too, so the *first*
    /// endpoint can be aimed precisely, not just the second.
    @State private var hoverPoint: CGPoint?
    /// The shape-side anchor (image coords) a line end would bind to right
    /// now — the little dot shown while hovering or dragging with the line
    /// tool near a shape's side. `nil` when nothing is in snapping range.
    @State private var snapAnchor: CGPoint?
    /// The bend dots (image coords) of the hovered line, all sitting on the
    /// stroke itself: the curve's midpoint, or the elbow runs' midpoints in
    /// corner mode. Dragging one reshapes the line. Empty when none hovered.
    @State private var bendDots: [CGPoint] = []
    /// The select tool's rubber band (image coords) while dragging over empty
    /// space; everything it touches is selected live.
    @State private var marqueeRect: CGRect?

    /// Hit slop in view points.
    private let handleHitRadius: CGFloat = 11
    private let bodyTolerance: CGFloat = 8
    /// How close (view points) to a shape's side the binding dot engages.
    private let bindSnapRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let fit = CanvasFit(pixelSize: model.pixelSize, captureScale: model.captureScale,
                                zoom: model.zoom, pan: model.pan, in: geo.size)

            ZStack(alignment: .topLeading) {
                canvas(fit: fit)
                    .gesture(drawGesture(fit: fit))
                    .simultaneousGesture(doubleClickGesture(fit: fit))
                    .simultaneousGesture(pinchGesture)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            if model.isPickingColor {
                                // Re-assert every move: SwiftUI resets the cursor on
                                // each mouse-moved, so a one-shot set wouldn't stick.
                                NSCursor.crosshair.set()
                                model.updateHoverColor(at: fit.toImage(location, clampedTo: model.pixelSize))
                            } else if model.tool == .measure, !model.isCropping,
                                      SettingsStore.shared.measureLoupe {
                                // Only tracked while the loupe can actually show —
                                // every update redraws the whole canvas.
                                hoverPoint = snapped(fit.toImage(location, clampedTo: model.pixelSize))
                            } else if hoverPoint != nil {
                                hoverPoint = nil
                            }
                            updateHoverSnap(at: location, fit: fit)
                            updateBendDots(at: location, fit: fit)
                        case .ended:
                            hoverPoint = nil
                            if session == nil {
                                snapAnchor = nil
                                bendDots = []
                            }
                            if model.isPickingColor {
                                NSCursor.arrow.set()
                                model.updateHoverColor(at: nil)
                            }
                        }
                    }
                textOverlay(fit: fit)
                loupeOverlay(fit: fit, canvasSize: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onDeleteCommand { model.deleteSelected() }
            // The model clamps zoom panning against the canvas's actual size.
            .onChange(of: geo.size, initial: true) { _, size in model.setCanvasSize(size) }
        }
        // Switching tools commits any in-progress text (and retires the loupe's
        // hover point, which is only tracked while the measure tool is armed).
        .onChange(of: model.tool) { _, _ in
            if model.editingTextID != nil { model.finishTextEditing() }
            hoverPoint = nil
            snapAnchor = nil
            bendDots = []
        }
        // Restore the arrow the moment picking ends (a lingering crosshair would
        // otherwise stay until the next mouse move).
        .onChange(of: model.isPickingColor) { _, picking in
            if !picking { NSCursor.arrow.set() }
        }
    }

    // MARK: - Canvas

    /// Past native 1:1 the capture is resampled with nearest-neighbor, so deep
    /// zoom shows sharp pixel squares (like the loupe) instead of interpolated
    /// blur — what pixel-accurate measuring needs.
    private func isMagnified(_ fit: CanvasFit) -> Bool {
        fit.scale * model.captureScale > 1.001
    }

    private func canvas(fit: CanvasFit) -> some View {
        Canvas { context, size in
            var base = Image(nsImage: model.baseImage)
            if isMagnified(fit) { base = base.interpolation(.none) }
            context.draw(base, in: fit.imageRect)
            if fit.scale >= 4 {
                drawPixelGrid(in: &context, fit: fit, canvasSize: size)
            }

            for annotation in model.annotations {
                if annotation.id == model.editingTextID {
                    // The editing TextField renders the text itself; a shape
                    // stays visible while its label is edited — only the label
                    // drawing is suppressed.
                    guard annotation.kind != .text else { continue }
                    draw(annotation, in: &context, fit: fit, editingLabel: true)
                } else {
                    draw(annotation, in: &context, fit: fit)
                }
            }
            if let draft = model.draft {
                draw(draft, in: &context, fit: fit)
            }
            if model.isCropping {
                drawCropOverlay(in: &context, fit: fit)
            } else if let selected = model.selectedAnnotation, selected.id != model.editingTextID {
                drawSelection(selected, in: &context, fit: fit)
            } else if model.selectedIDs.count > 1 {
                for annotation in model.annotations where model.selectedIDs.contains(annotation.id) {
                    drawMultiSelection(annotation, in: &context, fit: fit)
                }
            }
            if let marqueeRect {
                drawMarquee(marqueeRect, in: &context, fit: fit)
            }
            if let snapAnchor, !model.isCropping {
                drawSnapDot(at: fit.toView(snapAnchor), in: &context)
            }
            if !model.isCropping {
                for dot in bendDots {
                    drawSnapDot(at: fit.toView(dot), in: &context)
                }
            }
        }
        .contentShape(Rectangle())
        // Marquee pointer while cropping, hand while the move tool is armed.
        // (The color picker uses NSCursor's crosshair instead — see the hover
        // handler — as SwiftUI's PointerStyle has no crosshair.)
        .pointerStyle(pointerStyle)
    }

    private var pointerStyle: PointerStyle? {
        if model.isCropping { return .rectSelection }
        guard model.tool == .move, !model.isPickingColor else { return nil }
        if case .move = session?.kind { return .grabActive }
        return .grabIdle
    }

    private func draw(_ annotation: Annotation, in context: inout GraphicsContext,
                      fit: CanvasFit, editingLabel: Bool = false) {
        let width = annotation.lineWidth * fit.scale
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        let rect = CGRect(origin: fit.toView(annotation.boundingRect.origin),
                          size: CGSize(width: annotation.boundingRect.width * fit.scale,
                                       height: annotation.boundingRect.height * fit.scale))

        // Shape label: the stroke goes through a copied context whose clip
        // excludes the label's knockout rect, so the text sits on untouched
        // pixels. While editing an empty label, the hole is placeholder-sized.
        var shape = context
        if annotation.supportsLabel, annotation.hasLabel || editingLabel {
            let sizingText = annotation.text.isEmpty ? "Text" : annotation.text
            let hole = annotation.labelHoleRect(for: sizingText)
            let holeView = CGRect(origin: fit.toView(hole.origin),
                                  size: CGSize(width: hole.width * fit.scale,
                                               height: hole.height * fit.scale))
            shape.clip(to: Path(holeView), options: .inverse)
        }

        switch annotation.kind {
        case .line:
            var path = Path()
            let startTangent: CGPoint?, endTangent: CGPoint?
            if annotation.isCorner {
                let route = annotation.cornerRoute
                path.addPath(Path(roundedPolylinePath(route.map(fit.toView),
                                                      radius: annotation.cornerBendRadius * fit.scale)))
                startTangent = route[1]
                endTangent = route[route.count - 2]
            } else {
                path.move(to: fit.toView(annotation.start))
                if let control = annotation.curveControl {
                    path.addQuadCurve(to: fit.toView(annotation.end), control: fit.toView(control))
                    startTangent = control
                    endTangent = control
                } else {
                    path.addLine(to: fit.toView(annotation.end))
                    startTangent = nil
                    endTangent = nil
                }
            }
            for segment in lineCapSegments(from: annotation.start, to: annotation.end,
                                           startTangent: startTangent, endTangent: endTangent,
                                           startCap: annotation.startCap,
                                           endCap: annotation.endCap,
                                           lineWidth: annotation.lineWidth) {
                path.move(to: fit.toView(segment[0]))
                for point in segment.dropFirst() { path.addLine(to: fit.toView(point)) }
            }
            shape.stroke(path, with: .color(annotation.color), style: style)
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
        case .roundedRect:
            let radius = annotation.cornerRadius * fit.scale
            shape.stroke(Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                         with: .color(annotation.color), style: style)
        case .ellipse:
            shape.stroke(Path(ellipseIn: rect), with: .color(annotation.color), style: style)
        case .diamond:
            let radius = annotation.diamondCornerRadius * fit.scale
            shape.stroke(Path(diamondPath(in: rect, cornerRadius: radius)),
                         with: .color(annotation.color), style: style)
        case .pixelate:
            if let mosaic = model.pixelatedRegion(for: annotation) {
                var image = Image(decorative: mosaic, scale: 1)
                if isMagnified(fit) { image = image.interpolation(.none) }
                context.draw(image, in: rect)
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
        case .move, .select:
            break   // never annotation kinds
        }

        // The label itself, centered in the knockout (the TextField draws it
        // while editing). Line by line, each centered, to match the editing
        // field's center alignment on multi-line labels.
        if annotation.hasLabel, !editingLabel {
            let center = fit.toView(annotation.labelCenter)
            let lines = annotation.text.components(separatedBy: .newlines)
            let lineHeight = textRenderSize(" ", fontSize: annotation.fontSize,
                                            design: annotation.fontDesign).height * fit.scale
            let top = center.y - lineHeight * CGFloat(lines.count) / 2
            for (index, line) in lines.enumerated() {
                let label = Text(line)
                    .font(.system(size: annotation.fontSize * fit.scale, weight: .semibold,
                                  design: annotation.fontDesign.swiftUIDesign))
                    .foregroundStyle(annotation.color)
                context.draw(label, at: CGPoint(x: center.x,
                                                y: top + (CGFloat(index) + 0.5) * lineHeight),
                             anchor: .center)
            }
        }
    }

    /// Hairline grid on capture-pixel boundaries once pixels span 4+ view
    /// points — zoomed that deep the work is pixel-accurate, so show the
    /// pixels. Difference-blended so it reads on light and dark content alike.
    private func drawPixelGrid(in context: inout GraphicsContext, fit: CanvasFit,
                               canvasSize: CGSize) {
        let visible = fit.imageRect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !visible.isEmpty else { return }
        var path = Path()
        let firstCol = ((visible.minX - fit.imageRect.minX) / fit.scale).rounded(.down)
        let lastCol = ((visible.maxX - fit.imageRect.minX) / fit.scale).rounded(.up)
        for col in stride(from: firstCol, through: lastCol, by: 1) {
            let x = fit.imageRect.minX + col * fit.scale
            path.move(to: CGPoint(x: x, y: visible.minY))
            path.addLine(to: CGPoint(x: x, y: visible.maxY))
        }
        let firstRow = ((visible.minY - fit.imageRect.minY) / fit.scale).rounded(.down)
        let lastRow = ((visible.maxY - fit.imageRect.minY) / fit.scale).rounded(.up)
        for row in stride(from: firstRow, through: lastRow, by: 1) {
            let y = fit.imageRect.minY + row * fit.scale
            path.move(to: CGPoint(x: visible.minX, y: y))
            path.addLine(to: CGPoint(x: visible.maxX, y: y))
        }
        var grid = context
        grid.blendMode = .difference
        grid.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
    }

    /// The measure tool's distance label: white text on a rounded pill in
    /// the annotation color, placed by `measureLabelCenter` (on the midpoint,
    /// or beside a segment it would otherwise cover). Formatted by
    /// `measureLabelText` (shared with the export, so the two can never
    /// disagree) and stays correct no matter how zoomed-out the on-screen
    /// canvas is, since the length comes from the capture's pixel space,
    /// not the view.
    private func drawMeasureLabel(_ geometry: MeasureGeometry, in context: inout GraphicsContext,
                                  fit: CanvasFit, color: Color, fontSize: CGFloat, captureScale: CGFloat) {
        let label = measureLabelText(length: geometry.length, captureScale: captureScale,
                                     unit: SettingsStore.shared.measureUnit)
        // Shrunk when the pill would out-span the measured segment (shared
        // rule with the export, so what's copied is what's on screen).
        let fontSize = measureLabelFontSize(for: label, requested: fontSize,
                                            segmentLength: geometry.length)
        let text = Text(label)
            .font(.system(size: fontSize * fit.scale, weight: .semibold))
            .foregroundStyle(.white)
        let resolved = context.resolve(text)
        let huge = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = resolved.measure(in: huge)
        // Font-proportional, matching the export's pill exactly.
        let paddingX: CGFloat = fontSize * 0.35 * fit.scale
        let paddingY: CGFloat = fontSize * 0.18 * fit.scale
        let pillWidth = size.width + paddingX * 2
        let pillHeight = size.height + paddingY * 2
        let tickHalf = hypot(geometry.startTickA.x - geometry.start.x,
                             geometry.startTickA.y - geometry.start.y) * fit.scale
        let center = measureLabelCenter(start: fit.toView(geometry.start),
                                        end: fit.toView(geometry.end),
                                        pillSize: CGSize(width: pillWidth, height: pillHeight),
                                        tickHalf: tickHalf, bounds: fit.imageRect)
        let pillOrigin = CGPoint(x: center.x - pillWidth / 2, y: center.y - pillHeight / 2)
        let pillRect = CGRect(origin: pillOrigin, size: CGSize(width: pillWidth, height: pillHeight))
        context.fill(Path(roundedRect: pillRect, cornerRadius: pillHeight / 2), with: .color(color))
        context.draw(text, at: center, anchor: .center)
    }

    // MARK: - Loupe

    /// The point the loupe magnifies: the dragged measure endpoint, or — while
    /// the measure tool is armed but idle — the hovered point, so the *first*
    /// endpoint can be aimed too.
    private var activeLoupePoint: CGPoint? {
        if let loupePoint { return loupePoint }
        guard session == nil, model.tool == .measure, !model.isCropping,
              !model.isPickingColor, model.editingTextID == nil else { return nil }
        return hoverPoint
    }

    /// The loupe, as a real SwiftUI overlay (not Canvas drawing) so its side
    /// flip springs across the cursor and its appearance can scale/fade in,
    /// while its position still tracks the mouse 1:1 with no lag.
    @ViewBuilder
    private func loupeOverlay(fit: CanvasFit, canvasSize: CGSize) -> some View {
        let diameter: CGFloat = 120
        let radius = diameter / 2
        let gap: CGFloat = 10
        let point = SettingsStore.shared.measureLoupe ? activeLoupePoint : nil

        ZStack {
            if let point {
                let anchor = fit.toView(point)
                // Beside the cursor; springs to the left when the right side
                // wouldn't fit. `EditorController.minContentSize` guarantees
                // one side always does.
                let fitsRight = anchor.x + gap + diameter <= canvasSize.width
                MeasureLoupe(image: model.baseImage, pixelSize: model.pixelSize,
                             point: point, diameter: diameter)
                    .offset(x: fitsRight ? gap + radius : -(gap + radius))
                    .animation(.spring(duration: 0.3, bounce: 0.25), value: fitsRight)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .position(x: anchor.x,
                              y: min(max(anchor.y, radius),
                                     max(radius, canvasSize.height - radius)))
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.15), value: point != nil)
        .allowsHitTesting(false)
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

    /// A thin outline around each member of a multi-selection — no handles;
    /// resizing needs a single selection.
    private func drawMultiSelection(_ annotation: Annotation, in context: inout GraphicsContext,
                                    fit: CanvasFit) {
        let bounds = annotation.selectionBounds
        let rect = CGRect(origin: fit.toView(bounds.origin),
                          size: CGSize(width: bounds.width * fit.scale,
                                       height: bounds.height * fit.scale))
            .insetBy(dx: -4, dy: -4)
        context.stroke(Path(roundedRect: rect, cornerRadius: 5),
                       with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5))
    }

    /// The select tool's rubber band while dragging over empty space.
    private func drawMarquee(_ box: CGRect, in context: inout GraphicsContext, fit: CanvasFit) {
        let rect = CGRect(origin: fit.toView(box.origin),
                          size: CGSize(width: box.width * fit.scale, height: box.height * fit.scale))
        context.fill(Path(rect), with: .color(.accentColor.opacity(0.08)))
        context.stroke(Path(rect), with: .color(.accentColor.opacity(0.7)), lineWidth: 1)
    }

    // MARK: - Drag: draw / select / move / resize

    private func drawGesture(fit: CanvasFit) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if model.isCropping { cropChanged(value, fit: fit); return }
                if session == nil {
                    session = makeSession(pressView: value.startLocation, fit: fit)
                    // Hover doesn't fire during a drag: only a bend-dot drag
                    // keeps its dots alive (and tracking); any other drag
                    // could move the line out from under stale dots.
                    switch session?.kind {
                    case .resize(_, .curve), .resize(_, .cornerH), .resize(_, .cornerV): break
                    default: bendDots = []
                    }
                }
                guard var current = session else { return }

                let moved = hypot(value.location.x - value.startLocation.x,
                                  value.location.y - value.startLocation.y) > 2
                let image = fit.toImage(value.location, clampedTo: model.pixelSize)
                let shiftDown = NSEvent.modifierFlags.contains(.shift)

                switch current.kind {
                case .draw:
                    let isMeasure = model.tool == .measure
                    var start = current.pressImage
                    var end = image
                    if shiftDown, axisLocks(model.tool) { end = axisLocked(end, relativeTo: start) }
                    if squareSnaps(model.tool) { end = diagonalMagnet(end, relativeTo: start) }
                    if isMeasure {
                        start = snapped(start)
                        end = snapped(end)
                        loupePoint = end
                    }
                    var endBinding: ShapeBinding?
                    if model.tool == .line {
                        if let candidate = bindingCandidate(
                            at: image, in: model.annotations,
                            excluding: current.startBinding,
                            tolerance: bindSnapRadius / fit.scale) {
                            end = boundEndpoint(anchor: candidate.anchor,
                                                side: candidate.binding.side,
                                                lineWidth: model.lineWidth * model.creationSizeScale)
                            endBinding = candidate.binding
                            snapAnchor = candidate.anchor
                        } else {
                            end = axisMagnet(end, relativeTo: start)
                            snapAnchor = nil
                        }
                    }
                    let labelSize = isMeasure ? model.measureSize : model.fontSize
                    // Measure keeps its defaults — its label shrinks/relocates
                    // per segment instead, and should stay readable in exports.
                    let sizeScale = isMeasure ? 1 : model.creationSizeScale
                    var draft = Annotation(kind: model.tool, start: start, end: end,
                                           color: model.color,
                                           lineWidth: model.lineWidth * sizeScale,
                                           fontSize: labelSize * sizeScale)
                    if model.tool == .line {
                        draft.startCap = model.lineStartCap
                        draft.endCap = model.lineEndCap
                        draft.startBinding = current.startBinding
                        draft.endBinding = endBinding
                    }
                    model.draft = draft
                case .move(let id):
                    guard moved else { return }
                    let group = current.groupOriginals
                    if !current.didMutate {
                        model.snapshot()
                        // A line dragged bodily detaches from its shapes —
                        // unless the shape is moving along in the group.
                        if group.count > 1 {
                            for lineID in group.keys where annotationKind(lineID) == .line {
                                model.detachBindings(id: lineID, keepingShapesIn: Set(group.keys))
                            }
                        } else if annotationKind(id) == .line {
                            model.clearBindings(id: id)
                        }
                        current.didMutate = true
                        session = current
                    }
                    let dx = image.x - current.pressImage.x, dy = image.y - current.pressImage.y
                    let targets = group.count > 1 ? group
                        : [id: (current.originalStart, current.originalEnd)]
                    for (targetID, original) in targets {
                        var tdx = dx, tdy = dy
                        // Keep a measure line's endpoints on the pixel grid across moves.
                        if annotationKind(targetID) == .measure { tdx = tdx.rounded(); tdy = tdy.rounded() }
                        model.setPoints(id: targetID,
                                        start: CGPoint(x: original.start.x + tdx, y: original.start.y + tdy),
                                        end: CGPoint(x: original.end.x + tdx, y: original.end.y + tdy))
                    }
                case .marquee:
                    let box = rect(from: current.pressImage, to: image)
                    marqueeRect = box
                    let hits = Set(model.annotations
                        .filter { $0.selectionBounds.intersects(box) }.map(\.id))
                    if hits != model.selectedIDs { model.selectedIDs = hits }
                case .resize(let id, let handle):
                    guard moved else { return }
                    if !current.didMutate { model.snapshot(); current.didMutate = true; session = current }
                    let kind = annotationKind(id)
                    let isMeasure = kind == .measure
                    switch handle {
                    case .start:
                        var p = image
                        if shiftDown, let kind, axisLocks(kind) { p = axisLocked(p, relativeTo: current.originalEnd) }
                        if isMeasure { p = snapped(p); loupePoint = p }
                        if kind == .line {
                            resizeLineEndpoint(id: id, handle: .start, to: p, fit: fit)
                        } else {
                            model.setPoints(id: id, start: p, end: current.originalEnd)
                        }
                    case .end:
                        var p = image
                        if shiftDown, let kind, axisLocks(kind) { p = axisLocked(p, relativeTo: current.originalStart) }
                        if isMeasure { p = snapped(p); loupePoint = p }
                        if kind == .line {
                            resizeLineEndpoint(id: id, handle: .end, to: p, fit: fit)
                        } else {
                            model.setPoints(id: id, start: current.originalStart, end: p)
                        }
                    case .curve:
                        // The dot lands under the cursor; near-straight snaps
                        // back flat so the bow is easy to undo.
                        let value = curvatureValue(of: image, chordStart: current.originalStart,
                                                   chordEnd: current.originalEnd)
                        model.setCurvature(id: id, abs(value) * fit.scale < 5 ? 0 : value)
                        updateDraggedBendDots(id: id)
                    case .cornerH:
                        // The horizontal run follows the cursor's y, snapping
                        // back onto its baseline when close.
                        if let line = model.annotations.first(where: { $0.id == id }) {
                            let offset = image.y - line.elbowHBase
                            model.setElbowH(id: id, abs(offset) * fit.scale < 5 ? 0 : offset)
                            updateDraggedBendDots(id: id)
                        }
                    case .cornerV:
                        // The vertical trunk follows the cursor's x — likewise.
                        if let line = model.annotations.first(where: { $0.id == id }) {
                            let offset = image.x - line.elbowVBase
                            model.setElbowV(id: id, abs(offset) * fit.scale < 5 ? 0 : offset)
                            updateDraggedBendDots(id: id)
                        }
                    default:
                        let anchor = current.anchor ?? current.originalStart
                        var p = image
                        if let kind, squareSnaps(kind) { p = diagonalMagnet(p, relativeTo: anchor) }
                        model.setPoints(id: id, start: anchor, end: p)
                    }
                case .idle, .placeText, .placeCounter, .finishingEdit, .pickColor:
                    break
                }
            }
            .onEnded { value in
                // Hover events don't fire during a drag; seed the hover point
                // from the drag's endpoint so the loupe doesn't jump back to a
                // stale position until the mouse next moves.
                if let point = loupePoint { hoverPoint = point }
                loupePoint = nil
                snapAnchor = nil
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
                case .marquee:
                    marqueeRect = nil
                case .idle, .move, .resize:
                    break
                }
            }
    }

    /// Decides, on press, what this drag will do.
    private func makeSession(pressView: CGPoint, fit: CanvasFit) -> DragSession {
        let pressImage = fit.toImage(pressView, clampedTo: model.pixelSize)
        // Shift/⌘-click toggles annotations in and out of the selection.
        let toggling = NSEvent.modifierFlags.contains(.shift)
            || NSEvent.modifierFlags.contains(.command)

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

        // 2. With the line tool armed, a press near a bindable shape's side
        // starts a line bound there — taking precedence over selecting the
        // shape underneath, since the aim is clearly to connect it. Pressing
        // deeper inside the shape still selects it. But a press right on a
        // dot that already holds a line end grabs that end to re-route it —
        // a second line from the same anchor is still possible by pressing
        // elsewhere along the side.
        if model.tool == .line, !toggling,
           let candidate = bindingCandidate(at: pressImage, in: model.annotations,
                                            tolerance: bindSnapRadius / fit.scale) {
            if distance(pressView, fit.toView(candidate.anchor)) <= handleHitRadius,
               let bound = boundLineEnd(at: candidate.binding) {
                model.selectedID = bound.line.id
                return DragSession(kind: .resize(bound.line.id, bound.handle),
                                   pressImage: pressImage,
                                   originalStart: bound.line.start, originalEnd: bound.line.end)
            }
            model.selectedID = nil
            let start = boundEndpoint(anchor: candidate.anchor, side: candidate.binding.side,
                                      lineWidth: model.lineWidth * model.creationSizeScale)
            var session = DragSession(kind: .draw, pressImage: start)
            session.startBinding = candidate.binding
            return session
        }

        // 3. A bend dot of the hovered line — same hit rule that shows the
        // dots, so pressing what's visible always grabs it. Dragging reshapes
        // the line (a plain click just selects — the resize only mutates once
        // the drag moves).
        let tolerance = bodyTolerance / fit.scale
        if let line = model.annotations.last(where: {
            $0.kind == .line && $0.bodyContains(pressImage, tolerance: tolerance)
        }), let dot = line.bendDots.first(where: {
            distance(pressView, fit.toView($0.point)) <= handleHitRadius
        }) {
            model.selectedID = line.id
            return DragSession(kind: .resize(line.id, dot.handle), pressImage: pressImage,
                               originalStart: line.start, originalEnd: line.end)
        }

        // 4. The body of any annotation (topmost = last drawn). A toggle-click
        // adds it to / removes it from the selection; a plain press selects it
        // (keeping a multi-selection it's already part of) and drags everything
        // selected together.
        if let hit = model.annotations.last(where: { $0.bodyContains(pressImage, tolerance: tolerance) }) {
            if toggling {
                if model.selectedIDs.contains(hit.id) {
                    model.selectedIDs.remove(hit.id)
                } else {
                    model.selectedIDs.insert(hit.id)
                }
                return DragSession(kind: .idle, pressImage: pressImage)
            }
            if !model.selectedIDs.contains(hit.id) { model.selectedID = hit.id }
            var session = DragSession(kind: .move(hit.id), pressImage: pressImage,
                                      originalStart: hit.start, originalEnd: hit.end)
            if model.selectedIDs.count > 1 {
                for annotation in model.annotations where model.selectedIDs.contains(annotation.id) {
                    session.groupOriginals[annotation.id] = (annotation.start, annotation.end)
                }
            }
            return session
        }

        // 5. Empty space — deselect (a toggle-click leaves the selection
        // alone), then draw / place text / stamp a counter. The select tool
        // starts a marquee; the move tool draws nothing, so its press ends there.
        if !toggling { model.selectedID = nil }
        let kind: DragSession.Kind
        switch model.tool {
        case .select: kind = .marquee
        case .move: kind = .idle
        case .text: kind = .placeText
        case .counter: kind = .placeCounter
        default: kind = .draw
        }
        return DragSession(kind: kind, pressImage: pressImage)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// The topmost line with an end bound to exactly this shape side, if any.
    private func boundLineEnd(at binding: ShapeBinding) -> (line: Annotation, handle: ResizeHandle)? {
        for line in model.annotations.reversed() where line.kind == .line {
            if line.startBinding == binding { return (line, .start) }
            if line.endBinding == binding { return (line, .end) }
        }
        return nil
    }

    /// Trackpad pinch: continuous zoom, live-updating the title-bar percentage.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBaseZoom == nil { pinchBaseZoom = model.zoom }
                model.setZoom((pinchBaseZoom ?? 1) * value.magnification)
            }
            .onEnded { _ in pinchBaseZoom = nil }
    }

    private func annotationKind(_ id: UUID) -> EditTool? {
        model.annotations.first(where: { $0.id == id })?.kind
    }

    /// Re-snaps a dragged line endpoint to any shape side in range, updating
    /// its binding (or freeing it when nothing is nearby). The other end's
    /// exact spot is excluded so both ends can't land on the same point.
    private func resizeLineEndpoint(id: UUID, handle: ResizeHandle, to point: CGPoint, fit: CanvasFit) {
        let line = model.annotations.first { $0.id == id }
        let otherEnd = handle == .start ? line?.endBinding : line?.startBinding
        let candidate = bindingCandidate(at: point, in: model.annotations, excluding: otherEnd,
                                         tolerance: bindSnapRadius / fit.scale)
        snapAnchor = candidate?.anchor
        var snapped = candidate.map {
            boundEndpoint(anchor: $0.anchor, side: $0.binding.side,
                          lineWidth: line?.lineWidth ?? model.lineWidth)
        }
        if snapped == nil, let line {
            snapped = axisMagnet(point, relativeTo: handle == .start ? line.end : line.start)
        }
        model.setLineEndpoint(id: id, handle: handle, point: snapped ?? point,
                              binding: candidate?.binding)
    }

    /// Tracks the binding dot while the line tool is armed but not dragging.
    private func updateHoverSnap(at location: CGPoint, fit: CanvasFit) {
        guard session == nil else { return }
        guard model.tool == .line, !model.isCropping, !model.isPickingColor,
              model.editingTextID == nil else {
            if snapAnchor != nil { snapAnchor = nil }
            return
        }
        let point = fit.toImage(location, clampedTo: model.pixelSize)
        let anchor = bindingCandidate(at: point, in: model.annotations,
                                      tolerance: bindSnapRadius / fit.scale)?.anchor
        if anchor != snapAnchor { snapAnchor = anchor }
    }

    /// Tracks the bend dots while hovering: approaching a line's shaft offers
    /// its dots — dragging one reshapes the line.
    private func updateBendDots(at location: CGPoint, fit: CanvasFit) {
        guard session == nil else { return }
        guard !model.isCropping, !model.isPickingColor, model.editingTextID == nil else {
            if !bendDots.isEmpty { bendDots = [] }
            return
        }
        let point = fit.toImage(location, clampedTo: model.pixelSize)
        let tolerance = bodyTolerance / fit.scale
        let dots = model.annotations.last {
            $0.kind == .line && $0.bodyContains(point, tolerance: tolerance)
        }?.bendDots.map(\.point) ?? []
        if dots != bendDots { bendDots = dots }
    }

    /// Re-seeds the dots from the model mid-drag (hover doesn't fire then).
    private func updateDraggedBendDots(id: UUID) {
        bendDots = model.annotations.first { $0.id == id }?.bendDots.map(\.point) ?? []
    }

    /// The binding dot on a shape side's midpoint: pressing or releasing a
    /// line end while it shows snaps (and binds) the end there.
    private func drawSnapDot(at center: CGPoint, in context: inout GraphicsContext) {
        context.stroke(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9,
                                              width: 18, height: 18)),
                       with: .color(.accentColor.opacity(0.45)), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5,
                                            width: 11, height: 11)),
                     with: .color(.white))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                     with: .color(.accentColor))
    }

    /// Measure endpoints snap to integer pixel *boundaries* (not centers), so
    /// repeated measurements of the same edge always read the same and the
    /// boundary-to-boundary width convention is preserved.
    private func snapped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x.rounded(), y: p.y.rounded())
    }

    /// Which tools Shift constrains to the dominant axis.
    private func axisLocks(_ kind: EditTool) -> Bool {
        kind == .measure || kind == .line
    }

    /// `p` projected onto a horizontal or vertical through `anchor`, whichever
    /// is closer to the actual drag direction.
    private func axisLocked(_ p: CGPoint, relativeTo anchor: CGPoint) -> CGPoint {
        abs(p.x - anchor.x) >= abs(p.y - anchor.y)
            ? CGPoint(x: p.x, y: anchor.y)
            : CGPoint(x: anchor.x, y: p.y)
    }

    /// Magnetic pull for line endpoints: within a few degrees of horizontal or
    /// vertical, `p` snaps onto the axis through `anchor` so near-straight
    /// lines come out exactly straight. Beyond the threshold it's untouched.
    private func axisMagnet(_ p: CGPoint, relativeTo anchor: CGPoint) -> CGPoint {
        let slope = tan(4 * CGFloat.pi / 180)
        let dx = abs(p.x - anchor.x), dy = abs(p.y - anchor.y)
        if dy <= dx * slope { return CGPoint(x: p.x, y: anchor.y) }
        if dx <= dy * slope { return CGPoint(x: anchor.x, y: p.y) }
        return p
    }

    /// Which tools pull toward a square bounding box while drawing/resizing.
    private func squareSnaps(_ kind: EditTool) -> Bool {
        kind == .roundedRect || kind == .ellipse || kind == .diamond
    }

    /// The same pull toward the 45° diagonals: a box corner dragged within a
    /// few degrees of square snaps onto the diagonal through `anchor`, so
    /// ellipses become circles and rectangles/diamonds become squares.
    private func diagonalMagnet(_ p: CGPoint, relativeTo anchor: CGPoint) -> CGPoint {
        let slope = tan(4 * CGFloat.pi / 180)
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        guard abs(abs(dx) - abs(dy)) <= (abs(dx) + abs(dy)) * slope else { return p }
        let side = (abs(dx) + abs(dy)) / 2
        return CGPoint(x: anchor.x + (dx < 0 ? -side : side),
                       y: anchor.y + (dy < 0 ? -side : side))
    }

    // MARK: - Double-click: edit text / shape label

    private func doubleClickGesture(fit: CanvasFit) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                guard !model.isCropping else { return }
                let point = fit.toImage(value.location, clampedTo: model.pixelSize)
                let tolerance = bodyTolerance / fit.scale
                // On a bend dot, double-click toggles curve ↔ corner mode
                // instead of opening the line's label.
                if let line = model.annotations.last(where: {
                    $0.kind == .line && $0.bodyContains(point, tolerance: tolerance)
                }), line.bendDots.contains(where: {
                    distance(value.location, fit.toView($0.point)) <= handleHitRadius
                }) {
                    model.toggleLineBend(id: line.id)
                    updateDraggedBendDots(id: line.id)
                    return
                }
                if let hit = model.annotations.last(where: {
                    ($0.kind == .text || $0.supportsLabel)
                        && $0.bodyContains(point, tolerance: tolerance)
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
            let font = Font.system(size: annotation.fontSize * fit.scale, weight: .semibold,
                                   design: annotation.fontDesign.swiftUIDesign)
            if annotation.kind == .text {
                let origin = fit.toView(annotation.start)
                editingField(annotation: annotation, id: id, font: font, centered: false)
                    .frame(maxWidth: max(fit.imageRect.maxX - origin.x, 80), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: origin.x, y: origin.y)
            } else {
                // A shape label edits in place, centered on the label point.
                // The field gets a wide, session-constant frame — AppKit's
                // field editor doesn't reliably track a frame that grows while
                // typing (the text wrapped or clipped at the stale size), so
                // the frame must never need to grow. Center alignment keeps
                // the text visually anchored on the label point, and the
                // invisible surplus draws nothing. Only the vertical offset is
                // live: it re-centers the block when a newline changes the
                // line count.
                let center = fit.toView(annotation.labelCenter)
                let width = max(fit.imageRect.width, 300)
                let lineHeight = textRenderSize(" ", fontSize: annotation.fontSize,
                                                design: annotation.fontDesign).height * fit.scale
                let lines = CGFloat(max(model.editingText.components(separatedBy: .newlines).count, 1))
                editingField(annotation: annotation, id: id, font: font, centered: true)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: center.x - width / 2, y: center.y - lines * lineHeight / 2)
            }
        }
    }

    private func editingField(annotation: Annotation, id: UUID, font: Font, centered: Bool) -> some View {
        TextField("", text: Binding(get: { model.editingText }, set: { model.setEditingText($0) }),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(annotation.color)
            .multilineTextAlignment(centered ? .center : .leading)
            // SwiftUI forces the system gray on a TextField prompt, so draw
            // our own placeholder in the drawing color instead.
            .overlay(alignment: centered ? .center : .topLeading) {
                if model.editingText.isEmpty {
                    Text("Text")
                        .font(font)
                        .foregroundStyle(annotation.color.opacity(0.7))
                        .allowsHitTesting(false)
                }
            }
            .focused($textFieldFocused)
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

/// The measure tool's magnifier: the capture around `point` at 8 view-points
/// per pixel with nearest-neighbor sampling (a crisp pixel grid), a crosshair
/// on the snapped endpoint, and a ringed, shadowed circular chrome. Pure CPU
/// Core Graphics.
private struct MeasureLoupe: View {
    let image: NSImage
    let pixelSize: CGSize
    /// The magnified point (image coords, snapped) — sits at the center.
    let point: CGPoint
    let diameter: CGFloat

    private let magnification: CGFloat = 8   // view points per capture pixel

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

            guard let base = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            // Crop to just the visible neighborhood so CG never scales the
            // whole capture; `point` stays mapped to the center even when the
            // integral crop clamps at the image edges.
            let radiusPx = size.width / 2 / magnification + 1
            let crop = CGRect(x: point.x - radiusPx, y: point.y - radiusPx,
                              width: radiusPx * 2, height: radiusPx * 2)
                .integral.intersection(CGRect(origin: .zero, size: pixelSize))
            guard crop.width >= 1, crop.height >= 1, let sub = base.cropping(to: crop) else { return }

            context.withCGContext { cg in
                let drawRect = CGRect(x: center.x + (crop.minX - point.x) * magnification,
                                      y: center.y + (crop.minY - point.y) * magnification,
                                      width: crop.width * magnification,
                                      height: crop.height * magnification)
                // The GraphicsContext's CGContext is y-down; unflip locally so
                // the magnified crop isn't drawn upside down.
                cg.saveGState()
                cg.interpolationQuality = .none
                cg.translateBy(x: drawRect.minX, y: drawRect.maxY)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(sub, in: CGRect(origin: .zero, size: drawRect.size))
                cg.restoreGState()
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        // Crosshair through the center — exactly the snapped endpoint.
        .overlay {
            Path { p in
                p.move(to: CGPoint(x: 0, y: diameter / 2))
                p.addLine(to: CGPoint(x: diameter, y: diameter / 2))
                p.move(to: CGPoint(x: diameter / 2, y: 0))
                p.addLine(to: CGPoint(x: diameter / 2, y: diameter))
            }
            .stroke(.white.opacity(0.85), lineWidth: 1)
        }
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        // Hairline dark ring just outside the white one, so the loupe still
        // reads against light captures.
        .overlay(Circle().inset(by: -0.5).stroke(.black.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}
