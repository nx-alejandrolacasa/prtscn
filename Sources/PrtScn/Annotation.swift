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
        case .roundedRect: "S"
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
}

/// Ties one end of a line to the middle of a shape's side, so moving or
/// resizing the shape carries the line end with it.
struct ShapeBinding {
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
        return copy
    }

    /// Corner radius for the rounded-rectangle tool. Proportional to the
    /// stroke width (which carries the capture scale), *not* the shape's size,
    /// so growing a shape keeps its corners constant; capped only so a tiny
    /// shape can't out-round its own sides.
    var cornerRadius: CGFloat {
        min(lineWidth * 4, min(boundingRect.width, boundingRect.height) / 2)
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

    /// Where the label sits (image coords): the midpoint of a line/arrow, the
    /// center of a closed shape.
    var labelCenter: CGPoint {
        switch kind {
        case .line:
            return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
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
/// the snap point. The topmost such shape wins; `excluding` skips the shape
/// the line's other end is bound to, so one line can't collapse onto a
/// single shape.
func bindingCandidate(at point: CGPoint, in annotations: [Annotation],
                      excluding excluded: UUID? = nil, tolerance: CGFloat)
    -> (binding: ShapeBinding, anchor: CGPoint)? {
    for shape in annotations.reversed() where shape.isBindable && shape.id != excluded {
        let nearest = shape.bindingDistances(from: point).min { $0.distance < $1.distance }
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
        case .line, .measure:
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
        case .start, .end: return nil
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
            return distanceFromPoint(point, toSegment: start, end) <= tolerance + lineWidth / 2
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

    let headLength = min(max(lineWidth * 5.6, 24), length * maxHeadFraction)
    let spread = CGFloat.pi / 4                       // 45° open head

    func barb(_ angle: CGFloat) -> CGPoint {
        let rx = back.x * cos(angle) - back.y * sin(angle)
        let ry = back.x * sin(angle) + back.y * cos(angle)
        return CGPoint(x: tip.x + headLength * rx, y: tip.y + headLength * ry)
    }

    return ArrowGeometry(shaftStart: from, tip: tip,
                         leftBarb: barb(spread), rightBarb: barb(-spread))
}

/// The polylines to stroke for a line annotation: the shaft plus each end's
/// cap, in the inputs' coordinate space — shared by the on-screen canvas and
/// the export so they can never disagree. With an arrow head on both ends,
/// each head shrinks to under half the length so the two never collide.
func cappedLineSegments(from start: CGPoint, to end: CGPoint,
                        startCap: LineCap, endCap: LineCap,
                        lineWidth: CGFloat) -> [[CGPoint]] {
    var segments = [[start, end]]
    let headFraction: CGFloat = startCap == .arrow && endCap == .arrow ? 0.42 : 0.85

    let dx = end.x - start.x, dy = end.y - start.y
    let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
    let (px, py) = (-dy / length, dx / length)       // unit perpendicular
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
            segments.append([CGPoint(x: point.x + px * half, y: point.y + py * half),
                             CGPoint(x: point.x - px * half, y: point.y - py * half)])
        }
    }
    append(startCap, at: start, from: end)
    append(endCap, at: end, from: start)
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
