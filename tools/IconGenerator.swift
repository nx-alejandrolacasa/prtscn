import AppKit
import CoreText

// PrtScn app icon: two overlapping macOS windows — a screenshot of a screenshot.
// Style and palette are shared with the "insert" app icon: a muted gradient tile
// (sage-teal → steel blue) carrying glassy white cards with soft shadows, a top
// sheen and a hairline edge. The front window's title bar picks up insert's
// light-blue → deep-blue accent ramp.
//
// This generator emits BOTH representations of that one design:
//
//   • AppIcon.iconset / AppIcon-preview.png — the flat raster icon, drawn with
//     CoreGraphics. `iconutil` turns the iconset into Resources/AppIcon.icns,
//     the fallback for hosts where `actool` isn't available.
//   • Resources/AppIcon.icon — an Apple Icon Composer document: the same
//     windows as unmasked SVG layers over a document-level gradient fill, so
//     macOS 26 applies its own Liquid Glass material, shadows and specular
//     highlights per appearance (light / dark / clear / tinted).
//
// Both consume the same `windows` specs and the same `WindowLayout` solver, so
// the two icons can't drift apart. The flat one bakes in the effects macOS 26
// draws for itself (drop shadow, body sheen, hairline edge); the layered one
// deliberately leaves them out.
//
// Regeneration recipe: CLAUDE.md → "App icon".

// MARK: - Palette (insert's sage-teal / steel-blue background, blue accents)

private let bgTop = NSColor(srgbRed: 0.533, green: 0.667, blue: 0.710, alpha: 1)    // sage-teal (#88AAB5)
private let bgBottom = NSColor(srgbRed: 0.447, green: 0.565, blue: 0.655, alpha: 1) // steel blue (#7290A7)
private let cardFront = NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)   // clean white
private let cardBack = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.00, alpha: 1)    // faint lilac-white
private let lineTint = NSColor(srgbRed: 0.80, green: 0.81, blue: 0.87, alpha: 1)    // soft gray text lines
// The back window's chrome: a whisper of blue-gray so it reads as an inactive window.
private let barBackTop = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
private let barBackBottom = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.94, alpha: 1)
// Accent ramp, used for the front window's title bar: insert's badge blues.
private let brandTop = NSColor(srgbRed: 0.498, green: 0.639, blue: 0.820, alpha: 1)    // light blue (#7FA3D1)
private let brandBottom = NSColor(srgbRed: 0.208, green: 0.314, blue: 0.498, alpha: 1) // deep blue (#35507F)
// Traffic lights: the familiar macOS red / amber / green.
private let trafficDots = [
    NSColor(srgbRed: 1.00, green: 0.37, blue: 0.35, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.75, blue: 0.20, alpha: 1),
    NSColor(srgbRed: 0.24, green: 0.79, blue: 0.30, alpha: 1),
]

// MARK: - Helpers

private func roundedPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

private func linearGradient(_ cg: CGContext, _ top: NSColor, _ bottom: NSColor,
                            from start: CGPoint, to end: CGPoint) {
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: start, end: end, options: [])
}

/// Text lines in a window's content area: (width, left indent) as fractions of
/// the usable line width.
private typealias TextLine = (width: CGFloat, indent: CGFloat)

private enum WindowStyle {
    case back   // inactive: lilac-gray chrome + traffic lights
    case front  // active: brand-gradient chrome + toolbar field
}

// MARK: - Geometry

/// One window card, described as fractions of the design square so the same
/// spec can be resolved against the flat icon's inset tile (832pt) or the Icon
/// Composer canvas (1024pt).
private struct WindowSpec {
    let style: WindowStyle
    let center: CGPoint     // fraction of the design square, y-up
    let size: CGSize        // fraction of the design square
    let corner: CGFloat     // fraction of the design square's width
    let rotationDeg: CGFloat
    let lines: [TextLine]
}

/// Two overlapping windows: the inactive one behind (up-left, tilted up to the
/// right) and the active one in front (down-right, slight opposite tilt).
private let windows: [WindowSpec] = [
    WindowSpec(style: .back,
               center: CGPoint(x: 0.5 - 0.068, y: 0.5 + 0.117),
               size: CGSize(width: 0.53, height: 0.46),
               corner: 0.040, rotationDeg: 5,
               lines: [(0.55, 0.30), (1.0, 0), (0.86, 0), (0.66, 0)]),
    WindowSpec(style: .front,
               center: CGPoint(x: 0.5 + 0.102, y: 0.5 - 0.114),
               size: CGSize(width: 0.50, height: 0.42),
               corner: 0.040, rotationDeg: -4,
               lines: [(0.88, 0), (1.0, 0), (0.62, 0), (0.78, 0)]),
]

/// A spec resolved to absolute points, in a local space centred on the card and
/// oriented y-up (CoreGraphics). The SVG emitter flips it to y-down.
private struct WindowLayout {
    let size: CGSize
    let corner: CGFloat
    let card: CGRect
    let bar: CGRect
    let body: CGRect
    let dotRadius: CGFloat
    let dotCenters: [CGPoint]
    /// The front style's toolbar search field; nil for the back style.
    let field: CGRect?
    let lineRects: [CGRect]
    let lineCorner: CGFloat
    /// Title-bar gradient vector: vertical for the back style, diagonal for the
    /// brand ramp on the front one.
    let barGradient: (from: CGPoint, to: CGPoint)

    init(_ spec: WindowSpec, square: CGFloat) {
        let w = spec.size.width * square, h = spec.size.height * square
        size = CGSize(width: w, height: h)
        corner = spec.corner * square
        card = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

        let barH = h * 0.24
        bar = CGRect(x: card.minX, y: card.maxY - barH, width: w, height: barH)
        body = CGRect(x: card.minX, y: card.minY, width: w, height: h - barH)

        let dotR = barH * 0.17
        dotRadius = dotR
        let firstDotX = card.minX + w * 0.085
        let dotY = bar.midY
        switch spec.style {
        case .back:
            // Three traffic lights, evenly spaced.
            dotCenters = (0..<3).map { CGPoint(x: firstDotX + CGFloat($0) * dotR * 3.1, y: dotY) }
            field = nil
        case .front:
            // A single light plus a toolbar field, both knocked out in white.
            dotCenters = [CGPoint(x: firstDotX, y: dotY)]
            let fieldH = dotR * 1.5
            field = CGRect(x: firstDotX + dotR * 2.6, y: dotY - fieldH / 2,
                           width: w * 0.46, height: fieldH)
        }

        let lx = body.minX + w * 0.10
        let lw = w * 0.80
        let lh = h * 0.045
        let gap = h * 0.115
        lineCorner = lh / 2
        var ly = body.maxY - h * 0.14
        var rects: [CGRect] = []
        for line in spec.lines {
            rects.append(CGRect(x: lx + lw * line.indent, y: ly, width: lw * line.width, height: lh))
            ly -= gap
        }
        lineRects = rects

        switch spec.style {
        case .back:
            barGradient = (CGPoint(x: bar.midX, y: bar.maxY), CGPoint(x: bar.midX, y: bar.minY))
        case .front:
            barGradient = (CGPoint(x: bar.minX, y: bar.maxY), CGPoint(x: bar.maxX, y: bar.minY))
        }
    }
}

// MARK: - Flat icon (CoreGraphics)

/// Draws one window card, rotated about its own center, with a soft drop shadow,
/// a title bar, a few content lines, a body sheen and a hairline edge.
private func drawWindow(_ cg: CGContext, center: CGPoint, spec: WindowSpec, layout: WindowLayout) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: spec.rotationDeg * .pi / 180)

    let path = roundedPath(layout.card, layout.corner)

    // Drop shadow + body fill.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor(white: 0, alpha: 0.22).cgColor)
    cg.addPath(path)
    cg.setFillColor((spec.style == .front ? cardFront : cardBack).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Title bar: the top slice of the card.
    cg.saveGState(); cg.addPath(path); cg.clip()
    cg.clip(to: layout.bar)
    if spec.style == .front {
        linearGradient(cg, brandTop, brandBottom, from: layout.barGradient.from, to: layout.barGradient.to)
    } else {
        linearGradient(cg, barBackTop, barBackBottom, from: layout.barGradient.from, to: layout.barGradient.to)
    }
    cg.restoreGState()

    // Chrome details inside the title bar.
    let dotR = layout.dotRadius
    for (i, dot) in layout.dotCenters.enumerated() {
        let box = CGRect(x: dot.x - dotR, y: dot.y - dotR, width: dotR * 2, height: dotR * 2)
        cg.addEllipse(in: box)
        cg.setFillColor(spec.style == .front ? NSColor(white: 1, alpha: 0.92).cgColor
                                            : trafficDots[i].cgColor)
        cg.fillPath()
    }
    if let field = layout.field {
        cg.addPath(roundedPath(field, field.height / 2))
        cg.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor); cg.fillPath()
    }

    // Content lines below the chrome.
    for lr in layout.lineRects {
        cg.addPath(roundedPath(lr, layout.lineCorner)); cg.setFillColor(lineTint.cgColor); cg.fillPath()
    }

    // Glassy lift over the body only — the title bar keeps its own gradient.
    cg.saveGState(); cg.addPath(path); cg.clip(); cg.clip(to: layout.body)
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: layout.body.midX, y: layout.body.maxY),
                          end: CGPoint(x: layout.body.midX, y: layout.body.midY), options: [])
    cg.restoreGState()

    // Hairline edge.
    cg.addPath(path)
    cg.setStrokeColor(NSColor(white: 0, alpha: 0.05).cgColor)
    cg.setLineWidth(2); cg.strokePath()

    cg.restoreGState()
}

private func drawIcon(_ cg: CGContext) {
    let canvas: CGFloat = 1024
    let inset: CGFloat = 96
    let content = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let tilePath = roundedPath(content, content.width * 0.235)

    // Soft drop shadow beneath the tile.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor(white: 0, alpha: 0.18).cgColor)
    cg.addPath(tilePath); cg.setFillColor(bgBottom.cgColor); cg.fillPath()
    cg.restoreGState()

    // Diagonal gradient tile (sage-teal top-left → steel blue bottom-right).
    cg.saveGState(); cg.addPath(tilePath); cg.clip()
    let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray,
                            locations: [0, 1])!
    cg.drawLinearGradient(bgGrad,
                          start: CGPoint(x: content.minX, y: content.maxY),
                          end: CGPoint(x: content.maxX, y: content.minY), options: [])
    cg.restoreGState()

    for spec in windows {
        drawWindow(cg,
                   center: CGPoint(x: content.minX + spec.center.x * content.width,
                                   y: content.minY + spec.center.y * content.height),
                   spec: spec,
                   layout: WindowLayout(spec, square: content.width))
    }

    // Whisper-thin inner rim on the tile for a crisp edge.
    cg.saveGState()
    cg.addPath(tilePath)
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.30).cgColor)
    cg.setLineWidth(2); cg.strokePath()
    cg.restoreGState()
}

// MARK: - Layered icon (Apple Icon Composer)

// The .icon document is a declarative package: a top-level gradient `fill` for
// the background plus one `group` per foreground layer, each pointing at a
// full-bleed 1024×1024 SVG in Assets/. macOS 26 masks the squircle, applies the
// Liquid Glass material and draws the shadows, so the SVGs carry *shape and
// colour only* — no rounded-corner mask on the tile, no drop shadows, no body
// sheen, no hairline edge. (The window cards' own corner radii are shape, not
// mask, and stay.)
//
// Two constraints that are easy to get wrong and expensive to debug:
//
//   • `groups` is ordered front to back — groups[0] paints last, on top. The
//     front window therefore comes first. Reversing this hides the design.
//   • `translucency` must be explicitly disabled. Icon Composer defaults it on
//     at 0.5, which washes these near-white cards out against the pastel
//     background. `glass: true` stays: that's the treatment we want, and it
//     behaves once translucency is off.
//
// The background is the document's fill and never a layer — as a layer it would
// pick up its group's glass treatment, and the dark / clear / tinted variants
// are derived from the fill. `linear-gradient` stops run top-to-bottom with no
// direction control, so the flat icon's diagonal sage → gray ramp becomes a
// vertical one here. That's the one intentional difference between the two
// icons.

private let iconAssetNames: [WindowStyle: String] = [
    .front: "front-window.svg",
    .back: "back-window.svg",
]

/// Icon Composer writes colours as `<space>:r,g,b,a` with five decimals.
private func iconColor(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB)!
    return String(format: "extended-srgb:%.5f,%.5f,%.5f,%.5f",
                  s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
}

/// `icon.json`, modelled so `JSONEncoder` with `.sortedKeys` + `.prettyPrinted`
/// reproduces Icon Composer's own on-disk format exactly: alphabetical keys,
/// two-space indent, `" : "` separators, no trailing newline. Round-tripping the
/// package through Icon Composer therefore leaves no diff.
private struct IconDocument: Encodable {
    struct Fill: Encodable {
        let linearGradient: [String]
        enum CodingKeys: String, CodingKey { case linearGradient = "linear-gradient" }
    }
    struct Layer: Encodable {
        let glass: Bool
        let imageName: String
        let name: String
        enum CodingKeys: String, CodingKey { case glass, imageName = "image-name", name }
    }
    struct Shadow: Encodable { let kind: String; let opacity: Double }
    struct Translucency: Encodable { let enabled: Bool; let value: Double }
    struct Group: Encodable {
        let layers: [Layer]
        let shadow: Shadow
        let translucency: Translucency
    }
    struct Platforms: Encodable { let squares: String }

    let fill: Fill
    let groups: [Group]
    let supportedPlatforms: Platforms

    enum CodingKeys: String, CodingKey {
        case fill, groups
        case supportedPlatforms = "supported-platforms"
    }
}

// No `color-space-for-untagged-svg-colors`: omitting it is what makes the SVGs'
// untagged hex literals mean sRGB, which is the space the palette above is
// authored in. The key's only value Icon Composer 1.6 accepts is "display-p3"
// ("srgb" makes it refuse the document outright), and setting it changes
// nothing in actool's output — so the correct move is to leave it out.

private func iconDocument() -> IconDocument {
    // Front to back: reverse the draw order the flat icon uses.
    let groups = windows.reversed().map { spec in
        IconDocument.Group(
            layers: [IconDocument.Layer(glass: true,
                                       imageName: iconAssetNames[spec.style]!,
                                       name: spec.style == .front ? "Front Window" : "Back Window")],
            // Keep a shadow per group so the stacked cards separate from each
            // other and from the background.
            shadow: IconDocument.Shadow(kind: "neutral", opacity: 0.5),
            translucency: IconDocument.Translucency(enabled: false, value: 0.5))
    }
    return IconDocument(
        // Icon Composer gradients run top-to-bottom, so the flat icon's diagonal
        // ramp becomes a vertical one here — the one intentional difference.
        fill: IconDocument.Fill(linearGradient: [iconColor(bgTop), iconColor(bgBottom)]),
        groups: groups,
        supportedPlatforms: IconDocument.Platforms(squares: "shared"))
}

// MARK: SVG emission

/// Trims trailing zeros so the output reads like Icon Composer's own SVG export.
private func n(_ v: CGFloat) -> String {
    var s = String(format: "%.3f", v)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s == "-0" ? "0" : s
}

private func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X",
                  Int((s.redComponent * 255).rounded()),
                  Int((s.greenComponent * 255).rounded()),
                  Int((s.blueComponent * 255).rounded()))
}

/// Flips a y-up rect from `WindowLayout` into SVG's y-down local space.
private func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: -r.maxY, width: r.width, height: r.height)
}

private func svgRect(_ r: CGRect, radius: CGFloat, fill: String, opacity: CGFloat? = nil) -> String {
    let f = flip(r)
    let alpha = opacity.map { " fill-opacity=\"\(n($0))\"" } ?? ""
    return "<rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" "
        + "height=\"\(n(f.height))\" rx=\"\(n(radius))\" fill=\"\(fill)\"\(alpha)/>"
}

/// The title bar is the card's top slice: rounded where it meets the card's top
/// corners, square where it meets the body. Drawn as an explicit path so the
/// layer needs no clip mask.
private func svgTopBarPath(bar: CGRect, radius r: CGFloat, fill: String) -> String {
    let f = flip(bar)                       // y-down: f.minY is the card's top edge
    let l = f.minX, right = f.maxX, top = f.minY, bottom = f.maxY
    let d = "M\(n(l)),\(n(bottom)) V\(n(top + r)) A\(n(r)),\(n(r)) 0 0 1 \(n(l + r)),\(n(top)) "
        + "H\(n(right - r)) A\(n(r)),\(n(r)) 0 0 1 \(n(right)),\(n(top + r)) V\(n(bottom)) Z"
    return "<path d=\"\(d)\" fill=\"\(fill)\"/>"
}

private func svgLayer(for spec: WindowSpec, canvas: CGFloat) -> String {
    let layout = WindowLayout(spec, square: canvas)
    let center = CGPoint(x: spec.center.x * canvas, y: canvas - spec.center.y * canvas)
    // SVG's positive rotation is clockwise on a y-down canvas, CoreGraphics'
    // is counter-clockwise on a y-up one — hence the negation.
    let rotation = -spec.rotationDeg
    let gradientID = spec.style == .front ? "front-bar" : "back-bar"

    var body: [String] = []

    // Card body.
    body.append(svgRect(layout.card, radius: layout.corner,
                        fill: hex(spec.style == .front ? cardFront : cardBack)))

    // Title bar.
    body.append(svgTopBarPath(bar: layout.bar, radius: layout.corner, fill: "url(#\(gradientID))"))

    // Chrome: traffic lights, or one light plus the toolbar field.
    for (i, dot) in layout.dotCenters.enumerated() {
        let fill = spec.style == .front ? hex(.white) : hex(trafficDots[i])
        let alpha = spec.style == .front ? " fill-opacity=\"0.92\"" : ""
        body.append("<circle cx=\"\(n(dot.x))\" cy=\"\(n(-dot.y))\" r=\"\(n(layout.dotRadius))\" "
            + "fill=\"\(fill)\"\(alpha)/>")
    }
    if let field = layout.field {
        body.append(svgRect(field, radius: field.height / 2, fill: hex(.white), opacity: 0.75))
    }

    // Content lines.
    for lr in layout.lineRects {
        body.append(svgRect(lr, radius: layout.lineCorner, fill: hex(lineTint)))
    }

    let g = layout.barGradient
    let stops = spec.style == .front ? (brandTop, brandBottom) : (barBackTop, barBackBottom)
    let gradient = """
        <linearGradient id="\(gradientID)" gradientUnits="userSpaceOnUse" \
    x1="\(n(g.from.x))" y1="\(n(-g.from.y))" x2="\(n(g.to.x))" y2="\(n(-g.to.y))">
          <stop offset="0" stop-color="\(hex(stops.0))"/>
          <stop offset="1" stop-color="\(hex(stops.1))"/>
        </linearGradient>
    """

    let shapes = body.map { "    \($0)" }.joined(separator: "\n")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(n(canvas))" height="\(n(canvas))" \
    viewBox="0 0 \(n(canvas)) \(n(canvas))">
      <defs>
    \(gradient)
      </defs>
      <g transform="translate(\(n(center.x)) \(n(center.y))) rotate(\(n(rotation)))">
    \(shapes)
      </g>
    </svg>

    """
}

// MARK: Package writing

/// Writes `icon.json` and the layer SVGs into `path`, creating it if needed.
///
/// Files are written individually rather than by recreating the directory: the
/// package is a committed artifact that can also be opened and edited in Icon
/// Composer, and blowing it away would discard anything added there. Assets we
/// don't generate are left alone and reported instead.
private func writeIconComposerPackage(at path: String) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: path)
    let assets = root.appendingPathComponent("Assets")
    try! fm.createDirectory(at: assets, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! encoder.encode(iconDocument()).write(to: root.appendingPathComponent("icon.json"))

    var written: Set<String> = []
    for spec in windows {
        let name = iconAssetNames[spec.style]!
        written.insert(name)
        try! Data(svgLayer(for: spec, canvas: 1024).utf8)
            .write(to: assets.appendingPathComponent(name))
    }

    let onDisk = Set((try? fm.contentsOfDirectory(atPath: assets.path)) ?? [])
    let extras = onDisk.subtracting(written).filter { !$0.hasPrefix(".") }.sorted()
    if !extras.isEmpty {
        print("note: \(path)/Assets has files this generator doesn't write: \(extras.joined(separator: ", "))")
    }
    print("Wrote \(path)")
}

// MARK: - Render + output

private func renderMaster() -> NSBitmapImageRep {
    let px = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func png(_ master: NSBitmapImageRep, size: Int) -> Data {
    if size == 1024 { return master.representation(using: .png, properties: [:])! }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let master = renderMaster()

let fm = FileManager.default
let outputDir = "AppIcon.iconset"
try? fm.removeItem(atPath: outputDir)
try! fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let targets: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in targets {
    try! png(master, size: size).write(to: URL(fileURLWithPath: "\(outputDir)/\(name)"))
}
try! png(master, size: 1024).write(to: URL(fileURLWithPath: "AppIcon-preview.png"))
print("Wrote \(outputDir) and AppIcon-preview.png")

writeIconComposerPackage(at: "Resources/AppIcon.icon")
