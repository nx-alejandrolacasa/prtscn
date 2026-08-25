import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The drawing tools offered in the editor. Each drawing tool maps 1:1 to the
/// kind of annotation it produces; `move` is the exception — it draws nothing
/// and only selects, moves and resizes what's already there.
enum EditTool: String, CaseIterable, Identifiable {
    case move
    case line
    case measure
    case roundedRect
    case ellipse
    case diamond
    case pixelate
    case counter
    case text

    var id: Self { self }

    var label: String {
        switch self {
        case .move: "Move"
        case .line: "Line"
        case .measure: "Measure"
        case .roundedRect: "Rectangle"
        case .ellipse: "Ellipse"
        case .diamond: "Diamond"
        case .pixelate: "Pixelate"
        case .counter: "Step Number"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .move: "hand.raised"
        case .line: "line.diagonal"
        case .measure: "ruler"
        case .roundedRect: "rectangle"   // overridden by `icon`
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .pixelate: "eye.slash"
        case .counter: "1.circle.fill"
        case .text: "textformat"
        }
    }

    /// The unmodified key that arms the tool from the keyboard. The line tool
    /// also answers to A, which arms it with an arrow head; E doubles for the
    /// ellipse.
    var shortcutKey: Character {
        switch self {
        case .move: "H"
        case .line: "L"
        case .measure: "M"
        case .roundedRect: "R"
        case .ellipse: "C"
        case .diamond: "D"
        case .pixelate: "P"
        case .counter: "N"
        case .text: "T"
        }
    }

    /// Tooltip text: the label with its shortcut key.
    var hint: String { "\(label) (\(shortcutKey))" }

    /// The closed-shape tools grouped behind the palette's single shape button.
    static let shapes: [EditTool] = [.roundedRect, .ellipse, .diamond]

    var isShape: Bool { Self.shapes.contains(self) }

    /// Palette icon. The rounded-rectangle tool is drawn (no SF Symbol shows a
    /// rectangle with all four corners rounded), the rest use SF Symbols.
    @ViewBuilder var icon: some View {
        switch self {
        case .roundedRect:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1.8)
                .frame(width: 17, height: 13)
        default:
            Image(systemName: systemImage).font(.system(size: 15, weight: .medium))
        }
    }
}

/// How a line's shaft bends between its endpoints: a free quadratic bow, or
/// an orthogonal route of horizontal/vertical segments with rounded corners
/// (the flowchart connector look). Double-clicking a bend dot toggles
/// between the two.
enum LineBend: String {
    case curve, corner
}

/// What the line tool draws at one endpoint.
enum LineCap: String, CaseIterable, Identifiable {
    case none, arrow, bar

    var id: Self { self }

    var label: String {
        switch self {
        case .none: "None"
        case .arrow: "Arrow"
        case .bar: "Bar"
        }
    }
}

/// A cap's palette-button glyph, drawn rather than typeset — Unicode glyphs
/// (⊢, →) come from different font tables and their stroke weights clash. A
/// short shaft with the cap at its outer end, pointing left at the line's
/// start and right at its end.
struct LineCapIcon: Shape {
    let cap: LineCap
    let atStart: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: mid))
        path.addLine(to: CGPoint(x: rect.maxX, y: mid))

        let tipX = atStart ? rect.minX : rect.maxX
        let inward: CGFloat = atStart ? 1 : -1     // tip → back along the shaft
        let reach = rect.height / 2
        switch cap {
        case .none:
            break
        case .arrow:
            path.move(to: CGPoint(x: tipX + inward * reach, y: mid - reach))
            path.addLine(to: CGPoint(x: tipX, y: mid))
            path.addLine(to: CGPoint(x: tipX + inward * reach, y: mid + reach))
        case .bar:
            path.move(to: CGPoint(x: tipX, y: mid - reach))
            path.addLine(to: CGPoint(x: tipX, y: mid + reach))
        }
        return path
    }
}

/// A diagonal line with a perpendicular bar at each end — the tool button's
/// icon when the caps are bars, oriented like `line.diagonal`.
struct BarsLineIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: rect.minX + 1, y: rect.maxY - 1)
        let b = CGPoint(x: rect.maxX - 1, y: rect.minY + 1)
        // The line runs ↗, so its perpendicular is the ↘ diagonal.
        let half = rect.width * 0.24
        let (dx, dy) = (half * 0.7071, half * 0.7071)
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        for p in [a, b] {
            path.move(to: CGPoint(x: p.x - dx, y: p.y - dy))
            path.addLine(to: CGPoint(x: p.x + dx, y: p.y + dy))
        }
        return path
    }
}

/// The unit the measure tool reports distances in — a user preference.
enum MeasureUnit: String, CaseIterable, Identifiable {
    case points, pixels, both

    var id: Self { self }

    var label: String {
        switch self {
        case .points: "Points (pt)"
        case .pixels: "Pixels (px)"
        case .both: "Both"
        }
    }
}

/// The measure tool's label text, shared by the on-screen canvas and the
/// export so they can never disagree. `length` is in capture pixels;
/// `captureScale` converts to logical points. Built as a plain `String`:
/// interpolating an Int directly inside a `Text("...")` literal routes
/// through LocalizedStringKey, which applies locale thousands-grouping
/// (e.g. "1.152" on a Spanish locale) — not what we want for a raw
/// measurement.
func measureLabelText(length: CGFloat, captureScale: CGFloat, unit: MeasureUnit) -> String {
    let pixels = "\(Int(length.rounded())) px"
    let points = "\(Int((length / captureScale).rounded())) pt"
    switch unit {
    case .points: return points
    case .pixels: return pixels
    // On a 1x capture points and pixels coincide — collapse to one figure.
    case .both: return captureScale > 1 ? "\(points) · \(pixels)" : pixels
    }
}

/// The measure label's effective font size: the requested size, shrunk when
/// the pill would be wider than the measured segment (so the label can't
/// swamp a short measurement on a small capture), floored for legibility.
/// Shared by the on-screen canvas and the export so they render alike.
func measureLabelFontSize(for label: String, requested: CGFloat, segmentLength: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: requested, weight: .semibold)
    let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
    let pillWidth = textWidth + requested * 0.7   // the pill's font-proportional padding
    guard segmentLength > 0, pillWidth > segmentLength else { return requested }
    return max(requested * segmentLength / pillWidth, 8)
}

/// Where the measure pill sits, in whatever coordinate space the caller works
/// in: centered on the segment's midpoint while it fits comfortably along the
/// segment; otherwise offset perpendicular, clear of the ticks, so it doesn't
/// cover the very thing being measured. Clamped into `bounds` (the capture on
/// export, so the pill never bakes half-outside), preferring the side that
/// needs less clamping. Shared by the on-screen canvas and the export.
func measureLabelCenter(start: CGPoint, end: CGPoint, pillSize: CGSize,
                        tickHalf: CGFloat, bounds: CGRect) -> CGPoint {
    func clamped(_ c: CGPoint) -> CGPoint {
        CGPoint(x: min(max(c.x, bounds.minX + pillSize.width / 2), bounds.maxX - pillSize.width / 2),
                y: min(max(c.y, bounds.minY + pillSize.height / 2), bounds.maxY - pillSize.height / 2))
    }
    let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    let dx = end.x - start.x, dy = end.y - start.y
    let length = hypot(dx, dy)
    guard length > 0.0001, pillSize.width > length * 0.75 else { return clamped(mid) }
    let (px, py) = (-dy / length, dx / length)
    let offset = tickHalf + pillSize.height * 0.6
    let sideA = CGPoint(x: mid.x + px * offset, y: mid.y + py * offset)
    let sideB = CGPoint(x: mid.x - px * offset, y: mid.y - py * offset)
    let clampedA = clamped(sideA), clampedB = clamped(sideB)
    let driftA = hypot(clampedA.x - sideA.x, clampedA.y - sideA.y)
    let driftB = hypot(clampedB.x - sideB.x, clampedB.y - sideB.y)
    return driftA <= driftB ? clampedA : clampedB
}

/// Typeface family for text annotations — the three system designs.
enum FontDesign: String, CaseIterable, Identifiable {
    case sans, serif, monospaced

    var id: Self { self }

    var label: String {
        switch self {
        case .sans: "Sans-serif"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    var swiftUIDesign: Font.Design {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    var systemDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// The semibold system font in the given size and design — the single source of
/// truth shared by the on-screen canvas, hit-testing, and the export.
func annotationNSFont(size: CGFloat, design: FontDesign) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    if let descriptor = base.fontDescriptor.withDesign(design.systemDesign) {
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
    return base
}

/// A side of a bindable shape an arrow endpoint can attach to.
enum BindingSide: String, CaseIterable {
    case top, bottom, left, right

    /// Outward unit direction of the side — where a bound line end backs off.
    var outwardNormal: CGPoint {
        switch self {
        case .top: CGPoint(x: 0, y: -1)
        case .bottom: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: -1, y: 0)
        case .right: CGPoint(x: 1, y: 0)
        }
    }

    /// The axis a corner route travels when leaving/entering this side —
    /// perpendicular to the side itself.
    var routeAxis: RouteAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }
}

/// Direction of one leg of a corner line's orthogonal route.
enum RouteAxis {
    case horizontal, vertical

    var flipped: RouteAxis { self == .horizontal ? .vertical : .horizontal }
}

/// Where a bound line end actually sits: the anchor backed off outward by a
/// small line-width-proportional gap, so the arrow never touches the shape's
/// stroke. The snap dot still draws on the anchor itself.
func boundEndpoint(anchor: CGPoint, side: BindingSide, lineWidth: CGFloat) -> CGPoint {
    let gap = max(lineWidth * 1.5, 4)
    return CGPoint(x: anchor.x + side.outwardNormal.x * gap,
                   y: anchor.y + side.outwardNormal.y * gap)
}

/// Ties one end of a line to the middle of a shape's side, so moving or
/// resizing the shape carries the line end with it.
struct ShapeBinding: Equatable {
    var shapeID: UUID
    var side: BindingSide
}

/// One drawn annotation, stored in the capture's **pixel** coordinate space
/// (origin top-left) so it maps cleanly to both the on-screen canvas and the
/// full-resolution export. Non-destructive: shapes live as data until flattened.
struct Annotation: Identifiable {
    let id = UUID()
    var kind: EditTool
    /// Drag anchor and current point (pixel coords). For shapes these are two
    /// opposite corners / line endpoints; for text, `start` is the top-left.
    var start: CGPoint
    var end: CGPoint
    var color: Color
    /// Stroke width in pixels (shapes) — ignored for text.
    var lineWidth: CGFloat
    /// Font size in pixels — text only.
    var fontSize: CGFloat
    var text: String = ""
    /// Typeface family — text only.
    var fontDesign: FontDesign = .sans
    /// The badge number — step-counter only.
    var number: Int = 0
    /// End decorations — line tool only.
    var startCap: LineCap = .none
    var endCap: LineCap = .arrow
    /// Ties an end to a shape's side so the end follows the shape — line tool
    /// only. Cleared when the line is dragged bodily off its shapes.
    var startBinding: ShapeBinding?
    var endBinding: ShapeBinding?
    /// Signed bow of the shaft (pixels): the perpendicular offset of the
    /// curve's midpoint from the straight chord's midpoint — line tool only,
    /// 0 = straight. Relative to the chord, so moving, resizing and cropping
    /// carry the bow along.
    var curvature: CGFloat = 0
    /// How the shaft bends — line tool only.
    var bend: LineBend = .curve
    /// Corner mode's editable segments, as offsets so moves/crops carry them:
    /// the horizontal run sits at `elbowHBase + elbowH`, the vertical trunk
    /// at `elbowVBase + elbowV`. Both 0 = the clean minimal route.
    var elbowH: CGFloat = 0
    var elbowV: CGFloat = 0

    /// Bounding rect of `start`/`end`, normalized so width/height are positive.
    var boundingRect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Whether the shape is big enough to keep (filters out stray click-drags).
    var isMeaningful: Bool {
        if kind == .counter { return true }   // a stamp is always valid
        if kind == .text { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        // A 1–2 px measurement (a hairline border) is a legitimate use; the
        // endpoints snap to the pixel grid, so a stray click snaps to zero
        // length and is still discarded.
        if kind == .measure { return length >= 1 }
        return length > 4
    }

    /// Radius of the step-counter badge (image coords); `start` is its center.
    var counterRadius: CGFloat { fontSize * 0.9 }

    /// A copy with a fresh identity, shifted by `offset` (pixel coords) so it
    /// doesn't sit exactly atop the original. All style/content is preserved;
    /// the caller re-numbers a duplicated step counter. Bindings are not
    /// copied — the duplicate lands offset, no longer on the shape's side.
    func duplicated(offsetBy offset: CGPoint) -> Annotation {
        var copy = Annotation(kind: kind,
                              start: CGPoint(x: start.x + offset.x, y: start.y + offset.y),
                              end: CGPoint(x: end.x + offset.x, y: end.y + offset.y),
                              color: color, lineWidth: lineWidth, fontSize: fontSize)
        copy.text = text
        copy.fontDesign = fontDesign
        copy.number = number
        copy.startCap = startCap
        copy.endCap = endCap
        copy.curvature = curvature
        copy.bend = bend
        copy.elbowH = elbowH
        copy.elbowV = elbowV
        return copy
    }

    /// Corner radius for the rounded-rectangle tool. Proportional to the
    /// stroke width (which carries the capture scale), *not* the shape's size,
    /// so growing a shape keeps its corners constant; capped only so a tiny
    /// shape can't out-round its own sides.
    var cornerRadius: CGFloat {
        min(lineWidth * 5.5, min(boundingRect.width, boundingRect.height) / 2)
    }

    /// Corner radius for the diamond tool — deliberately subtler than the
    /// rounded rectangle's, just enough to soften the points. Constant across
    /// shape sizes, like `cornerRadius`.
    var diamondCornerRadius: CGFloat { lineWidth * 2 }
}

/// The diamond tool's outline: a rhombus inscribed in `rect` (vertices at the
/// edge midpoints) with softly rounded corners — shared by the on-screen
/// canvas and the export so they can never disagree. The radius is capped per
/// aspect ratio so the tangent arcs at the sharp corners of a skewed diamond
/// can't overrun their edges.
func diamondPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let top = CGPoint(x: rect.midX, y: rect.minY)
    let right = CGPoint(x: rect.maxX, y: rect.midY)
    let bottom = CGPoint(x: rect.midX, y: rect.maxY)
    let left = CGPoint(x: rect.minX, y: rect.midY)

    let w = max(rect.width, 0.0001), h = max(rect.height, 0.0001)
    let edge = hypot(w, h) / 2
    let maxRadius = min(h / w, w / h) * edge / 2
    let radius = min(cornerRadius, maxRadius)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: (left.x + top.x) / 2, y: (left.y + top.y) / 2))
    for (corner, next) in [(top, right), (right, bottom), (bottom, left), (left, top)] {
        path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
    }
    path.closeSubpath()
    return path
}

// MARK: - Curved lines

extension Annotation {
    /// Whether the shaft bows. Sub-pixel values count as straight so a
    /// degenerate control point can't sneak in.
    var isCurved: Bool { kind == .line && abs(curvature) > 0.5 }

    /// Unit perpendicular of the start→end chord (zero-length-safe).
    private var chordPerpendicular: CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.0001)
        return CGPoint(x: -dy / length, y: dx / length)
    }

    /// The point the shaft passes through at its middle — the curve dot the
    /// user grabs and drags to bow the line. The chord midpoint while straight.
    var curveMidpoint: CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        guard isCurved else { return mid }
        let perp = chordPerpendicular
        return CGPoint(x: mid.x + perp.x * curvature, y: mid.y + perp.y * curvature)
    }

    /// The quadratic Bézier control that puts the curve through
    /// `curveMidpoint` at t = 0.5; `nil` while straight.
    var curveControl: CGPoint? {
        guard isCurved else { return nil }
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let perp = chordPerpendicular
        return CGPoint(x: mid.x + perp.x * curvature * 2, y: mid.y + perp.y * curvature * 2)
    }
}

// MARK: - Corner lines

extension Annotation {
    var isCorner: Bool { kind == .line && bend == .corner }

    /// How far each 90° corner is rounded. Stroke-proportional, like the
    /// rounded rectangle's corners; the path builder caps it per corner.
    var cornerBendRadius: CGFloat { lineWidth * 4 }

    /// Length of the connection stub kept at an endpoint when its run is
    /// dragged away from it. Longer than an arrow head (5.6× the stroke), so
    /// a head on the stub still shows some straight shaft behind it.
    private var elbowStub: CGFloat { max(lineWidth * 8, 28) }

    /// The axis the route leaves `start` along: perpendicular to a bound
    /// side; a free end takes the complement of the other end's bound side
    /// (one clean elbow), or the dominant travel direction when both are free.
    var cornerStartAxis: RouteAxis {
        if let side = startBinding?.side { return side.routeAxis }
        if let side = endBinding?.side { return side.routeAxis.flipped }
        return abs(end.x - start.x) >= abs(end.y - start.y) ? .horizontal : .vertical
    }

    /// The axis the route enters `end` along — same rules, from the other end.
    var cornerEndAxis: RouteAxis {
        if let side = endBinding?.side { return side.routeAxis }
        if let side = startBinding?.side { return side.routeAxis.flipped }
        return abs(end.x - start.x) >= abs(end.y - start.y) ? .vertical : .horizontal
    }

    /// Baseline (image coords) the `elbowH` offset shifts the editable
    /// horizontal run away from; which endpoint (or the midline) anchors it
    /// depends on the route's orientation.
    var elbowHBase: CGFloat {
        switch (cornerStartAxis, cornerEndAxis) {
        case (.horizontal, .vertical): start.y
        case (.vertical, .horizontal): end.y
        case (.vertical, .vertical): (start.y + end.y) / 2
        case (.horizontal, .horizontal): 0   // no editable horizontal run
        }
    }

    /// Baseline the `elbowV` offset shifts the vertical trunk away from.
    var elbowVBase: CGFloat {
        switch (cornerStartAxis, cornerEndAxis) {
        case (.horizontal, .vertical): end.x
        case (.vertical, .horizontal): start.x
        case (.horizontal, .horizontal): (start.x + end.x) / 2
        case (.vertical, .vertical): 0   // no editable vertical trunk
        }
    }

    /// Keeps a free middle segment on the outward side of a bound endpoint,
    /// at least a stub away, so the route never doubles back through the shape.
    private func outwardClamp(_ value: CGFloat, past coordinate: CGFloat,
                              side: BindingSide) -> CGFloat {
        switch side {
        case .right, .bottom: max(value, coordinate + elbowStub)
        case .left, .top: min(value, coordinate - elbowStub)
        }
    }

    /// Corner mode's orthogonal route (image coords), start → end. Its
    /// orientation follows `cornerStartAxis`/`cornerEndAxis`, so a bound end
    /// always leaves its shape perpendicular to the bound side: perpendicular
    /// axes give the classic two-segment elbow, matching axes a three-segment
    /// Z through the midline. Dragging a run off its endpoint inserts a short
    /// stub there, so the connection stays in place. Every segment is
    /// horizontal or vertical.
    var cornerRoute: [CGPoint] {
        switch (cornerStartAxis, cornerEndAxis) {
        case (.horizontal, .vertical):
            let hy = start.y + elbowH
            let vx = end.x + elbowV
            var points = [start]
            if abs(elbowH) > 0.5 {
                let jx = start.x + (vx >= start.x ? elbowStub : -elbowStub)
                points.append(CGPoint(x: jx, y: start.y))
                points.append(CGPoint(x: jx, y: hy))
            }
            points.append(CGPoint(x: vx, y: hy))
            if abs(elbowV) > 0.5 {
                let ky = end.y + (hy <= end.y ? -elbowStub : elbowStub)
                points.append(CGPoint(x: vx, y: ky))
                points.append(CGPoint(x: end.x, y: ky))
            }
            points.append(end)
            return points
        case (.vertical, .horizontal):
            let vx = start.x + elbowV
            let hy = end.y + elbowH
            var points = [start]
            if abs(elbowV) > 0.5 {
                let jy = start.y + (hy >= start.y ? elbowStub : -elbowStub)
                points.append(CGPoint(x: start.x, y: jy))
                points.append(CGPoint(x: vx, y: jy))
            }
            points.append(CGPoint(x: vx, y: hy))
            if abs(elbowH) > 0.5 {
                let kx = end.x + (vx <= end.x ? -elbowStub : elbowStub)
                points.append(CGPoint(x: kx, y: hy))
                points.append(CGPoint(x: kx, y: end.y))
            }
            points.append(end)
            return points
        case (.horizontal, .horizontal):
            var vx = elbowVBase + elbowV
            if let side = startBinding?.side { vx = outwardClamp(vx, past: start.x, side: side) }
            if let side = endBinding?.side { vx = outwardClamp(vx, past: end.x, side: side) }
            return [start, CGPoint(x: vx, y: start.y), CGPoint(x: vx, y: end.y), end]
        case (.vertical, .vertical):
            var hy = elbowHBase + elbowH
            if let side = startBinding?.side { hy = outwardClamp(hy, past: start.y, side: side) }
            if let side = endBinding?.side { hy = outwardClamp(hy, past: end.y, side: side) }
            return [start, CGPoint(x: start.x, y: hy), CGPoint(x: end.x, y: hy), end]
        }
    }

    /// The grabbable bend dots, all sitting on the stroke itself: the single
    /// dot riding the curve, or — in corner mode — one on each editable run
    /// at its midpoint (`.cornerH` drags vertically, `.cornerV` horizontally).
    /// A Z route has a single editable middle segment, so a single dot.
    var bendDots: [(handle: ResizeHandle, point: CGPoint)] {
        guard isCorner else { return [(.curve, curveMidpoint)] }
        let route = cornerRoute
        switch (cornerStartAxis, cornerEndAxis) {
        case (.horizontal, .vertical):
            let hy = start.y + elbowH
            let vx = end.x + elbowV
            let runStartX = abs(elbowH) > 0.5 ? route[2].x : start.x
            let trunkEndY = abs(elbowV) > 0.5 ? route[route.count - 3].y : end.y
            return [(.cornerH, CGPoint(x: (runStartX + vx) / 2, y: hy)),
                    (.cornerV, CGPoint(x: vx, y: (hy + trunkEndY) / 2))]
        case (.vertical, .horizontal):
            let vx = start.x + elbowV
            let hy = end.y + elbowH
            let trunkStartY = abs(elbowV) > 0.5 ? route[2].y : start.y
            let runEndX = abs(elbowH) > 0.5 ? route[route.count - 3].x : end.x
            return [(.cornerH, CGPoint(x: (vx + runEndX) / 2, y: hy)),
                    (.cornerV, CGPoint(x: vx, y: (trunkStartY + hy) / 2))]
        case (.horizontal, .horizontal):
            return [(.cornerV, CGPoint(x: route[1].x, y: (start.y + end.y) / 2))]
        case (.vertical, .vertical):
            return [(.cornerH, CGPoint(x: (start.x + end.x) / 2, y: route[1].y))]
        }
    }

    /// Where the label anchors: the horizontal run's dot in corner mode, the
    /// curve's midpoint otherwise.
    var bendPoint: CGPoint { isCorner ? bendDots[0].point : curveMidpoint }
}

/// A polyline with every interior corner rounded by a tangent arc — the
/// corner-mode shaft, shared by the on-screen canvas and the export so they
/// can never disagree. The radius is capped per corner so short legs can't
/// be overrun by their arcs.
func roundedPolylinePath(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first, let last = points.last, points.count >= 2 else { return path }
    path.move(to: first)
    for index in 1..<(points.count - 1) {
        let previous = points[index - 1], corner = points[index], next = points[index + 1]
        let capped = min(radius,
                         hypot(corner.x - previous.x, corner.y - previous.y) / 2,
                         hypot(next.x - corner.x, next.y - corner.y) / 2)
        if capped > 0.01 {
            path.addArc(tangent1End: corner, tangent2End: next, radius: capped)
        } else {
            path.addLine(to: corner)
        }
    }
    path.addLine(to: last)
    return path
}

/// The curvature a drag of the curve dot to `p` asks for: the signed
/// perpendicular offset of `p` from the chord a–b, matching
/// `Annotation.curveMidpoint`'s sign convention so the dot lands under the
/// cursor (its along-chord component is ignored — the bow stays centered).
func curvatureValue(of p: CGPoint, chordStart a: CGPoint, chordEnd b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = max(hypot(dx, dy), 0.0001)
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    return ((p.x - mid.x) * -dy + (p.y - mid.y) * dx) / length
}

/// Shortest distance from `p` to the quadratic Bézier a–control–b, measured
/// against a fine polyline flattening — plenty for hit-testing a stroked shaft.
func distanceFromPoint(_ p: CGPoint, toQuadCurve a: CGPoint, control: CGPoint, _ b: CGPoint) -> CGFloat {
    var best = CGFloat.greatestFiniteMagnitude
    var previous = a
    for step in 1...24 {
        let t = CGFloat(step) / 24
        let s = 1 - t
        let point = CGPoint(x: s * s * a.x + 2 * s * t * control.x + t * t * b.x,
                            y: s * s * a.y + 2 * s * t * control.y + t * t * b.y)
        best = min(best, distanceFromPoint(p, toSegment: previous, point))
        previous = point
    }
    return best
}

/// Geometry for a bold, modern arrow drawn as a single-weight stroke (round
/// caps/joins): a shaft to the tip plus an open chevron head — the look of the
/// `arrow.up.right` SF Symbol. All points share the inputs' coordinate space.
struct ArrowGeometry {
    let shaftStart: CGPoint
    let tip: CGPoint
    /// The two open-head endpoints; stroke them as `leftBarb → tip → rightBarb`
    /// so the tip gets a rounded join.
    let leftBarb: CGPoint
    let rightBarb: CGPoint
}

// MARK: - Shape labels

extension Annotation {
    /// Whether double-click can attach a centered text label to this annotation.
    /// Measure has its own pixel-count label; pixelate/counter/text don't apply.
    var supportsLabel: Bool {
        switch kind {
        case .line, .roundedRect, .ellipse, .diamond: return true
        default: return false
        }
    }

    /// True once the label has actual content.
    var hasLabel: Bool {
        supportsLabel && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the label sits (image coords): the bend point of a line/arrow
    /// (riding the bow or elbow when it bends), the center of a closed shape.
    var labelCenter: CGPoint {
        switch kind {
        case .line:
            return bendPoint
        default:
            return CGPoint(x: boundingRect.midX, y: boundingRect.midY)
        }
    }

    /// The knockout rect around the label: the shape's stroke is clipped out of
    /// it, so the text sits directly on the untouched capture with breathing
    /// room on all sides. `displayText` overrides the stored text while editing
    /// (live sizing, and a placeholder-sized hole while still empty).
    func labelHoleRect(for displayText: String? = nil) -> CGRect {
        let size = textRenderSize(displayText ?? text, fontSize: fontSize, design: fontDesign)
        return CGRect(x: labelCenter.x - size.width / 2, y: labelCenter.y - size.height / 2,
                      width: size.width, height: size.height)
            .insetBy(dx: -fontSize * 0.4, dy: -fontSize * 0.2)
    }
}

// MARK: - Shape binding

extension Annotation {
    /// Shapes a line end can bind to. The ellipse binds at its bounding rect's
    /// side midpoints, which lie exactly on the ellipse itself; the diamond's
    /// side midpoints are its vertices.
    var isBindable: Bool {
        switch kind {
        case .roundedRect, .ellipse, .diamond: return true
        default: return false
        }
    }

    /// The midpoint of `side` of the bounding rect — where a bound line end sits.
    func anchorPoint(for side: BindingSide) -> CGPoint {
        let r = boundingRect
        switch side {
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        }
    }

    /// The side a corner route attaches to best for a line coming from
    /// `point`: the one facing it, judged from the shape's center and
    /// normalized by its extents so a wide shape doesn't over-prefer its
    /// long sides.
    func bestBindingSide(toward point: CGPoint) -> BindingSide {
        let r = boundingRect
        let dx = (point.x - r.midX) / max(r.width, 1)
        let dy = (point.y - r.midY) / max(r.height, 1)
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .bottom : .top
    }

    private var sideSegments: [(side: BindingSide, a: CGPoint, b: CGPoint)] {
        let r = boundingRect
        return [(.top, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)),
                (.bottom, CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)),
                (.left, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)),
                (.right, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))]
    }

    /// How close `point` comes to each attachable spot: the bounding rect's
    /// sides for rectangles and ellipses, but the vertices themselves for the
    /// diamond — its corners are the snap targets, so the dot engages when
    /// approaching a corner, not somewhere along the rect's phantom sides.
    fileprivate func bindingDistances(from point: CGPoint) -> [(side: BindingSide, distance: CGFloat)] {
        if kind == .diamond {
            return BindingSide.allCases.map { side in
                let anchor = anchorPoint(for: side)
                return (side, hypot(point.x - anchor.x, point.y - anchor.y))
            }
        }
        return sideSegments.map { (side: $0.side, distance: distanceFromPoint(point, toSegment: $0.a, $0.b)) }
    }
}

/// The bindable shape spot within `tolerance` of `point` (image coords), if
/// any: approaching a side (or, on a diamond, a corner) offers its anchor as
/// the snap point. The topmost such shape wins; `excluding` skips the exact
/// spot the line's other end is bound to — both ends may share a shape, just
/// not the same point.
func bindingCandidate(at point: CGPoint, in annotations: [Annotation],
                      excluding excluded: ShapeBinding? = nil, tolerance: CGFloat)
    -> (binding: ShapeBinding, anchor: CGPoint)? {
    for shape in annotations.reversed() where shape.isBindable {
        let nearest = shape.bindingDistances(from: point)
            .filter { excluded != ShapeBinding(shapeID: shape.id, side: $0.side) }
            .min { $0.distance < $1.distance }
        if let nearest, nearest.distance <= tolerance {
            return (ShapeBinding(shapeID: shape.id, side: nearest.side),
                    shape.anchorPoint(for: nearest.side))
        }
    }
    return nil
}

// MARK: - Selection & manipulation

/// A draggable handle on a selected annotation.
enum ResizeHandle {
    case start, end                                       // arrow endpoints
    case curve                                            // the line's bow dot
    case cornerH, cornerV                                 // elbow run dots
    case topLeft, topRight, bottomLeft, bottomRight       // shape corners
}

extension Annotation {
    /// The text's rendered bounds (image coords). Empty text gets a minimum
    /// width so it can still be hit and outlined while selected.
    var textRect: CGRect {
        CGRect(origin: start, size: textRenderSize(text, fontSize: fontSize, design: fontDesign))
    }

    /// Handle points shown when this annotation is selected (image coords).
    /// Text has none — it's move-only.
    var handles: [(handle: ResizeHandle, point: CGPoint)] {
        switch kind {
        case .line:
            return [(.start, start), (.end, end)] + bendDots
        case .measure:
            return [(.start, start), (.end, end)]
        case .roundedRect, .ellipse, .diamond, .pixelate:
            let r = boundingRect
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)),
                    (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                    (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
        case .text, .counter, .move:
            return []
        }
    }

    /// The corner that stays put while dragging `handle` (nil for arrow ends).
    func anchor(for handle: ResizeHandle) -> CGPoint? {
        let r = boundingRect
        switch handle {
        case .topLeft: return CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.minX, y: r.minY)
        case .start, .end, .curve, .cornerH, .cornerV: return nil
        }
    }

    /// Whether `point` (image coords) is on this annotation's body, within
    /// `tolerance` — used to select/move it.
    func bodyContains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        // The label counts as body: it can sit off the stroke (the middle of a
        // shape, astride a thin line), yet must still select/move/re-edit.
        if hasLabel, labelHoleRect().contains(point) { return true }
        switch kind {
        case .line, .measure:
            let slop = tolerance + lineWidth / 2
            if isCorner {
                let route = cornerRoute
                return (0..<(route.count - 1)).contains {
                    distanceFromPoint(point, toSegment: route[$0], route[$0 + 1]) <= slop
                }
            }
            if let control = curveControl {
                return distanceFromPoint(point, toQuadCurve: start, control: control, end) <= slop
            }
            return distanceFromPoint(point, toSegment: start, end) <= slop
        case .roundedRect, .ellipse, .diamond, .pixelate:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return textRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .counter:
            return hypot(point.x - start.x, point.y - start.y) <= counterRadius + tolerance
        case .move:
            return false   // never an annotation kind
        }
    }
}

/// The rendered size of a text annotation, matching the export font. Measured
/// line by line at a uniform line height — the same stacking the on-screen
/// canvas and the export draw with — because `NSAttributedString.size()` lays
/// out a single line only, which undersized multi-line text everywhere.
func textRenderSize(_ text: String, fontSize: CGFloat, design: FontDesign) -> CGSize {
    let font = annotationNSFont(size: fontSize, design: design)
    func lineSize(_ line: String) -> CGSize {
        NSAttributedString(string: line, attributes: [.font: font]).size()
    }
    let lines = (text.isEmpty ? " " : text).components(separatedBy: .newlines)
    return CGSize(width: lines.map { lineSize($0).width }.max() ?? 0,
                  height: lineSize(" ").height * CGFloat(lines.count))
}

/// Shortest distance from `p` to the segment `a`–`b`.
func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

func arrowGeometry(from: CGPoint, to tip: CGPoint, lineWidth: CGFloat,
                   maxHeadFraction: CGFloat = 0.85) -> ArrowGeometry {
    let dx = tip.x - from.x, dy = tip.y - from.y
    let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
    let ux = dx / length, uy = dy / length          // unit direction
    let back = (x: -ux, y: -uy)                      // tip → tail direction

    let headLength = min(max(lineWidth * 3.4, 14), length * maxHeadFraction)
    let spread = CGFloat.pi / 4                       // 45° open head

    func barb(_ angle: CGFloat) -> CGPoint {
        let rx = back.x * cos(angle) - back.y * sin(angle)
        let ry = back.x * sin(angle) + back.y * cos(angle)
        return CGPoint(x: tip.x + headLength * rx, y: tip.y + headLength * ry)
    }

    return ArrowGeometry(shaftStart: from, tip: tip,
                         leftBarb: barb(spread), rightBarb: barb(-spread))
}

/// The polylines to stroke for a line's end decorations, in the inputs'
/// coordinate space — shared by the on-screen canvas and the export so they
/// can never disagree. `startTangent`/`endTangent` are the points the shaft
/// leaves toward / arrives from when it bends (the curve's control point, or
/// an elbow route's neighboring corners), so caps align with the shaft's real
/// end direction instead of the chord; `nil` falls back to the opposite
/// endpoint. With an arrow head on both ends, each head shrinks to under
/// half the length so the two never collide.
func lineCapSegments(from start: CGPoint, to end: CGPoint,
                     startTangent: CGPoint?, endTangent: CGPoint?,
                     startCap: LineCap, endCap: LineCap,
                     lineWidth: CGFloat) -> [[CGPoint]] {
    var segments: [[CGPoint]] = []
    let headFraction: CGFloat = startCap == .arrow && endCap == .arrow ? 0.42 : 0.85
    let half = max(lineWidth * 4, 12)                // matches the measure ticks

    func append(_ cap: LineCap, at point: CGPoint, from other: CGPoint) {
        switch cap {
        case .none:
            break
        case .arrow:
            let g = arrowGeometry(from: other, to: point, lineWidth: lineWidth,
                                  maxHeadFraction: headFraction)
            // leftBarb → tip → rightBarb, so the tip gets a rounded join.
            segments.append([g.leftBarb, g.tip, g.rightBarb])
        case .bar:
            let dx = point.x - other.x, dy = point.y - other.y
            let length = max(hypot(dx, dy), 0.0001)
            let (px, py) = (-dy / length, dx / length)   // unit perpendicular
            segments.append([CGPoint(x: point.x + px * half, y: point.y + py * half),
                             CGPoint(x: point.x - px * half, y: point.y - py * half)])
        }
    }
    append(startCap, at: start, from: startTangent ?? end)
    append(endCap, at: end, from: endTangent ?? start)
    return segments
}

/// Geometry for the measure tool: the main segment plus a short perpendicular
/// "cutting" tick at each end (like a dimension line), the midpoint for the
/// pixel-count label, and the segment's true length (in the same coordinate
/// space as `from`/`to` — the capture's pixel space, so it's the real pixel
/// distance regardless of on-screen zoom).
struct MeasureGeometry {
    let start: CGPoint
    let end: CGPoint
    let startTickA: CGPoint
    let startTickB: CGPoint
    let endTickA: CGPoint
    let endTickB: CGPoint
    let mid: CGPoint
    let length: CGFloat
}

func measureGeometry(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> MeasureGeometry {
    let dx = to.x - from.x, dy = to.y - from.y
    let length = (dx * dx + dy * dy).squareRoot()
    let (ux, uy) = length > 0.0001 ? (dx / length, dy / length) : (1, 0)
    let (px, py) = (-uy, ux)                         // unit perpendicular
    // Long enough to clearly poke out past the endpoint's selection-handle
    // dot (11 view points across), not just peek out from behind it.
    let half = max(lineWidth * 4, 12)

    return MeasureGeometry(
        start: from, end: to,
        startTickA: CGPoint(x: from.x + px * half, y: from.y + py * half),
        startTickB: CGPoint(x: from.x - px * half, y: from.y - py * half),
        endTickA: CGPoint(x: to.x + px * half, y: to.y + py * half),
        endTickB: CGPoint(x: to.x - px * half, y: to.y - py * half),
        mid: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2),
        length: length)
}
