import AppKit
import CoreText

// PrtScn app icon: two overlapping macOS windows — a screenshot of a screenshot.
// Style and palette are shared with the "Stuff" app icon: a pastel gradient tile
// (lilac → warm apricot) carrying glassy white cards with soft shadows, a top
// sheen and a hairline edge. The front window's title bar picks up the warm
// purple → orange brand ramp so both hues sing.
//
// Regeneration recipe: CLAUDE.md → "App icon".

// MARK: - Palette (pastel purple + warm orange)

private let bgTop = NSColor(srgbRed: 0.82, green: 0.78, blue: 0.99, alpha: 1)       // pastel lilac
private let bgBottom = NSColor(srgbRed: 0.99, green: 0.86, blue: 0.72, alpha: 1)    // warm apricot
private let cardFront = NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)   // clean white
private let cardBack = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.00, alpha: 1)    // faint lilac-white
private let lineTint = NSColor(srgbRed: 0.80, green: 0.81, blue: 0.87, alpha: 1)    // soft gray text lines
// The back window's chrome: a whisper of lilac so it reads as an inactive window.
private let barBackTop = NSColor(srgbRed: 0.91, green: 0.90, blue: 0.96, alpha: 1)
private let barBackBottom = NSColor(srgbRed: 0.86, green: 0.85, blue: 0.93, alpha: 1)
// Brand ramp, used for the front window's title bar.
private let brandTop = NSColor(srgbRed: 0.66, green: 0.52, blue: 0.98, alpha: 1)    // purple
private let brandBottom = NSColor(srgbRed: 0.99, green: 0.66, blue: 0.42, alpha: 1) // orange
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

private func linearGradient(_ cg: CGContext, _ rect: CGRect, _ top: NSColor, _ bottom: NSColor,
                            start: CGPoint? = nil, end: CGPoint? = nil) {
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad,
                          start: start ?? CGPoint(x: rect.midX, y: rect.maxY),
                          end: end ?? CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// Text lines in a window's content area: (width, left indent) as fractions of
/// the usable line width.
private typealias TextLine = (width: CGFloat, indent: CGFloat)

private enum WindowStyle {
    case back   // inactive: lilac-gray chrome + traffic lights
    case front  // active: brand-gradient chrome + toolbar field
}

/// Draws one window card, rotated about its own center, with a soft drop shadow,
/// a title bar, a few content lines, a body sheen and a hairline edge.
private func drawWindow(_ cg: CGContext, center: CGPoint, size: CGSize, corner: CGFloat,
                        rotation: CGFloat, style: WindowStyle, lines: [TextLine]) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: rotation)

    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let path = roundedPath(rect, corner)

    // Drop shadow + body fill.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor(white: 0, alpha: 0.22).cgColor)
    cg.addPath(path)
    cg.setFillColor((style == .front ? cardFront : cardBack).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Title bar: the top slice of the card.
    let barH = size.height * 0.24
    let bar = CGRect(x: rect.minX, y: rect.maxY - barH, width: size.width, height: barH)
    cg.saveGState(); cg.addPath(path); cg.clip()
    cg.clip(to: bar)
    if style == .front {
        linearGradient(cg, bar, brandTop, brandBottom,
                       start: CGPoint(x: bar.minX, y: bar.maxY),
                       end: CGPoint(x: bar.maxX, y: bar.minY))
    } else {
        linearGradient(cg, bar, barBackTop, barBackBottom)
    }
    cg.restoreGState()

    // Chrome details inside the title bar.
    let dotR = barH * 0.17
    switch style {
    case .back:
        // Three traffic lights, sampled from the brand ramp.
        for (i, color) in trafficDots.enumerated() {
            let cxDot = bar.minX + size.width * 0.085 + CGFloat(i) * dotR * 3.1
            let box = CGRect(x: cxDot - dotR, y: bar.midY - dotR, width: dotR * 2, height: dotR * 2)
            cg.addEllipse(in: box); cg.setFillColor(color.cgColor); cg.fillPath()
        }
    case .front:
        // A single light plus a toolbar field, both knocked out in white.
        let cxDot = bar.minX + size.width * 0.085
        let box = CGRect(x: cxDot - dotR, y: bar.midY - dotR, width: dotR * 2, height: dotR * 2)
        cg.addEllipse(in: box)
        cg.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor); cg.fillPath()
        let fieldH = dotR * 1.5
        let field = CGRect(x: cxDot + dotR * 2.6, y: bar.midY - fieldH / 2,
                           width: size.width * 0.46, height: fieldH)
        cg.addPath(roundedPath(field, fieldH / 2))
        cg.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor); cg.fillPath()
    }

    // Content lines below the chrome.
    let body = CGRect(x: rect.minX, y: rect.minY, width: size.width, height: size.height - barH)
    let lx = body.minX + size.width * 0.10
    let lw = size.width * 0.80
    let lh = size.height * 0.045
    let gap = size.height * 0.115
    var ly = body.maxY - size.height * 0.14
    for line in lines {
        let lr = CGRect(x: lx + lw * line.indent, y: ly, width: lw * line.width, height: lh)
        cg.addPath(roundedPath(lr, lh / 2)); cg.setFillColor(lineTint.cgColor); cg.fillPath()
        ly -= gap
    }

    // Glassy lift over the body only — the title bar keeps its own gradient.
    cg.saveGState(); cg.addPath(path); cg.clip(); cg.clip(to: body)
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                          end: CGPoint(x: body.midX, y: body.midY), options: [])
    cg.restoreGState()

    // Hairline edge.
    cg.addPath(path)
    cg.setStrokeColor(NSColor(white: 0, alpha: 0.05).cgColor)
    cg.setLineWidth(2); cg.strokePath()

    cg.restoreGState()
}

// MARK: - Compose

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

    // Pastel diagonal gradient tile (lilac top-left → apricot bottom-right).
    cg.saveGState(); cg.addPath(tilePath); cg.clip()
    linearGradient(cg, content, bgTop, bgBottom,
                   start: CGPoint(x: content.minX, y: content.maxY),
                   end: CGPoint(x: content.maxX, y: content.minY))
    cg.restoreGState()

    // Two overlapping windows: the inactive one behind (up-left, tilted up to the
    // right) and the active one in front (down-right, slight opposite tilt).
    let cx = content.midX, cy = content.midY
    let deg = CGFloat.pi / 180

    drawWindow(cg,
               center: CGPoint(x: cx - content.width * 0.068, y: cy + content.height * 0.117),
               size: CGSize(width: content.width * 0.53, height: content.height * 0.46),
               corner: content.width * 0.040, rotation: 5 * deg,
               style: .back,
               lines: [(0.55, 0.30), (1.0, 0), (0.86, 0), (0.66, 0)])

    drawWindow(cg,
               center: CGPoint(x: cx + content.width * 0.102, y: cy - content.height * 0.114),
               size: CGSize(width: content.width * 0.50, height: content.height * 0.42),
               corner: content.width * 0.040, rotation: -4 * deg,
               style: .front,
               lines: [(0.88, 0), (1.0, 0), (0.62, 0), (0.78, 0)])

    // Whisper-thin inner rim on the tile for a crisp edge.
    cg.saveGState()
    cg.addPath(tilePath)
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.30).cgColor)
    cg.setLineWidth(2); cg.strokePath()
    cg.restoreGState()
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
