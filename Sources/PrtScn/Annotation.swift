import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The drawing tools offered in the editor. A tool maps 1:1 to the kind of
/// annotation it produces.
enum EditTool: String, CaseIterable, Identifiable {
    case arrow
    case line
    case measure
    case rectangle
    case roundedRect
    case ellipse
    case pixelate
    case counter
    case text

    var id: Self { self }

    var label: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .measure: "Measure"
        case .rectangle: "Rectangle"
        case .roundedRect: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .pixelate: "Pixelate"
        case .counter: "Step Number"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .measure: "ruler"
        case .rectangle: "rectangle"
        case .roundedRect: "rectangle"   // overridden by `icon`
        case .ellipse: "circle"
        case .pixelate: "eye.slash"
        case .counter: "1.circle.fill"
        case .text: "textformat"
        }
    }

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
        return (dx * dx + dy * dy).squareRoot() > 4
    }

    /// Radius of the step-counter badge (image coords); `start` is its center.
    var counterRadius: CGFloat { fontSize * 0.9 }

    /// A copy with a fresh identity, shifted by `offset` (pixel coords) so it
    /// doesn't sit exactly atop the original. All style/content is preserved;
    /// the caller re-numbers a duplicated step counter.
    func duplicated(offsetBy offset: CGPoint) -> Annotation {
        var copy = Annotation(kind: kind,
                              start: CGPoint(x: start.x + offset.x, y: start.y + offset.y),
                              end: CGPoint(x: end.x + offset.x, y: end.y + offset.y),
                              color: color, lineWidth: lineWidth, fontSize: fontSize)
        copy.text = text
        copy.fontDesign = fontDesign
        copy.number = number
        return copy
    }

    /// Corner radius for the rounded-rectangle tool, proportional to the
    /// shorter side and clamped so it reads as a squircle, not a stadium.
    var cornerRadius: CGFloat {
        let r = min(boundingRect.width, boundingRect.height) * 0.18
        return min(max(r, 4), 64)
    }
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
        case .arrow, .line, .measure:
            return [(.start, start), (.end, end)]
        case .rectangle, .roundedRect, .ellipse, .pixelate:
            let r = boundingRect
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)),
                    (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                    (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
        case .text, .counter:
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
        switch kind {
        case .arrow, .line, .measure:
            return distanceFromPoint(point, toSegment: start, end) <= tolerance + lineWidth / 2
        case .rectangle, .roundedRect, .ellipse, .pixelate:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return textRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .counter:
            return hypot(point.x - start.x, point.y - start.y) <= counterRadius + tolerance
        }
    }
}

/// The rendered size of a text annotation, matching the export font.
func textRenderSize(_ text: String, fontSize: CGFloat, design: FontDesign) -> CGSize {
    let string = NSAttributedString(
        string: text.isEmpty ? " " : text,
        attributes: [.font: annotationNSFont(size: fontSize, design: design)])
    return string.size()
}

/// Shortest distance from `p` to the segment `a`–`b`.
func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

func arrowGeometry(from: CGPoint, to tip: CGPoint, lineWidth: CGFloat) -> ArrowGeometry {
    let dx = tip.x - from.x, dy = tip.y - from.y
    let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
    let ux = dx / length, uy = dy / length          // unit direction
    let back = (x: -ux, y: -uy)                      // tip → tail direction

    let headLength = min(max(lineWidth * 5.6, 24), length * 0.85)
    let spread = CGFloat.pi / 4                       // 45° open head

    func barb(_ angle: CGFloat) -> CGPoint {
        let rx = back.x * cos(angle) - back.y * sin(angle)
        let ry = back.x * sin(angle) + back.y * cos(angle)
        return CGPoint(x: tip.x + headLength * rx, y: tip.y + headLength * ry)
    }

    return ArrowGeometry(shaftStart: from, tip: tip,
                         leftBarb: barb(spread), rightBarb: barb(-spread))
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
