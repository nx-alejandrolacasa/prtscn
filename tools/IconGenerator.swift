import AppKit
import CoreText

// PrtScn app icon: a dark keycap with a subtly glowing "PrtScn" legend
// (bottom-left) and the menu-bar camera glyph (top-right). Single accent color,
// gentle glow, no rim. Change `accent` to recolor.
//
// Regeneration recipe: CLAUDE.md → "App icon".

// MARK: - Palette

private let bezelTop = NSColor(srgbRed: 0.22, green: 0.22, blue: 0.24, alpha: 1)
private let bezelBottom = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
private let faceTop = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
private let faceBottom = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)
// Purple → blue gradient (bottom-left to top-right).
private let gradientStops: [(CGFloat, NSColor)] = [
    (0.0, NSColor(srgbRed: 0.52, green: 0.34, blue: 0.96, alpha: 1)),  // purple
    (1.0, NSColor(srgbRed: 0.20, green: 0.62, blue: 1.00, alpha: 1)),  // blue
]
private let glowTint = NSColor(srgbRed: 0.42, green: 0.50, blue: 1.00, alpha: 0.65)

// MARK: - Helpers

private func roundedPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

private func verticalGradient(_ cg: CGContext, _ rect: CGRect, _ top: NSColor, _ bottom: NSColor) {
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY),
                          end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// Filled glyph path for `text` at baseline origin (0,0).
private func textPath(_ text: String, font: NSFont) -> CGPath {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    let path = CGMutablePath()
    for run in runs {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        let runFont = attrs[kCTFontAttributeName as String] as! CTFont
        for i in 0..<CTRunGetGlyphCount(run) {
            var glyph = CGGlyph()
            var position = CGPoint()
            CTRunGetGlyphs(run, CFRangeMake(i, 1), &glyph)
            CTRunGetPositions(run, CFRangeMake(i, 1), &position)
            if let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                let transform = CGAffineTransform(translationX: position.x, y: position.y)
                path.addPath(glyphPath, transform: transform)
            }
        }
    }
    return path
}

private func brandGradient(alpha: CGFloat) -> CGGradient {
    let colors = gradientStops.map { $0.1.withAlphaComponent(alpha).cgColor } as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                      locations: gradientStops.map { $0.0 })!
}

/// Fills the current clip with the diagonal purple→blue gradient.
private func fillBrand(_ cg: CGContext, extent: CGRect) {
    cg.drawLinearGradient(brandGradient(alpha: 1),
                          start: CGPoint(x: extent.minX, y: extent.minY),
                          end: CGPoint(x: extent.maxX, y: extent.maxY),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Fills the outline of `path` (stroked to `width`) with the gradient.
private func strokeBrand(_ cg: CGContext, _ path: CGPath, width: CGFloat, extent: CGRect) {
    cg.saveGState()
    cg.addPath(path); cg.setLineWidth(width); cg.setLineJoin(.round); cg.setLineCap(.round)
    cg.replacePathWithStrokedPath(); cg.clip()
    fillBrand(cg, extent: extent)
    cg.restoreGState()
}

/// Four separate L-shaped viewfinder corner marks inside `rect` (no connecting
/// square).
private func cornerBrackets(in rect: CGRect, arm: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY - arm))   // top-left
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
    p.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))   // top-right
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
    p.move(to: CGPoint(x: rect.maxX, y: rect.minY + arm))   // bottom-right
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
    p.move(to: CGPoint(x: rect.minX + arm, y: rect.minY))   // bottom-left
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + arm))
    return p
}

/// An SF Symbol filled with the gradient (transparent elsewhere).
private func gradientSymbol(_ name: String, px: Int) -> CGImage? {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.6, weight: .medium)
    let glyph = symbol.withSymbolConfiguration(config) ?? symbol

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    fillBrand(ctx.cgContext, extent: CGRect(x: 0, y: 0, width: px, height: px))
    let size = glyph.size
    let scale = min(CGFloat(px) / size.width, CGFloat(px) / size.height) * 0.9
    let dw = size.width * scale, dh = size.height * scale
    let dest = NSRect(x: (CGFloat(px) - dw) / 2, y: (CGFloat(px) - dh) / 2, width: dw, height: dh)
    glyph.draw(in: dest, from: .zero, operation: .destinationIn, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

// MARK: - Compose

private func drawIcon(_ cg: CGContext) {
    let canvas: CGFloat = 1024
    let inset: CGFloat = 64
    let content = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let bezelPath = roundedPath(content, content.width * 0.22)
    let glowColor = glowTint.cgColor

    // Drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: NSColor(white: 0, alpha: 0.38).cgColor)
    cg.addPath(bezelPath); cg.setFillColor(bezelBottom.cgColor); cg.fillPath()
    cg.restoreGState()

    // Dark keycap with a soft top sheen.
    cg.saveGState(); cg.addPath(bezelPath); cg.clip()
    verticalGradient(cg, content, bezelTop, bezelBottom)
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.08).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: content.midX, y: content.maxY),
                          end: CGPoint(x: content.midX, y: content.maxY - content.height * 0.4), options: [])
    cg.restoreGState()

    // Recessed inner face.
    let face = content.insetBy(dx: 52, dy: 52)
    let facePath = roundedPath(face, content.width * 0.22 * 0.80)
    cg.saveGState(); cg.addPath(facePath); cg.clip()
    verticalGradient(cg, face, faceTop, faceBottom)
    cg.restoreGState()

    // Glowing rim around the whole face: a subtle halo then a gradient core.
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 18, color: glowColor)
    cg.addPath(facePath); cg.setStrokeColor(glowTint.cgColor); cg.setLineWidth(5); cg.strokePath()
    cg.restoreGState()
    strokeBrand(cg, facePath, width: 4, extent: content)

    let pad = face.width * 0.09

    // Legend, bottom-left — San Francisco (Apple's keyboard font), subtle glow.
    let probeFont = NSFont.systemFont(ofSize: 200, weight: .medium)
    let probeWidth = NSAttributedString(string: "PrtScn", attributes: [.font: probeFont]).size().width
    let fontSize = 200 * (face.width * 0.58) / probeWidth
    let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

    let raw = textPath("PrtScn", font: font)
    let bounds = raw.boundingBoxOfPath
    var move = CGAffineTransform(translationX: face.minX + pad - bounds.minX,
                                 y: face.minY + pad - bounds.minY)
    let glyphsPath = raw.copy(using: &move)!
    // Halo (bloom outside the letters), then gradient body.
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 14, color: glowColor)
    cg.addPath(glyphsPath); cg.setFillColor(glowTint.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(glyphsPath); cg.clip()
    fillBrand(cg, extent: content)
    cg.restoreGState()

    // Camera + viewfinder corner brackets, top-right (no connecting square).
    let glyphSize = face.width * 0.30
    let glyphRect = CGRect(x: face.maxX - pad - glyphSize, y: face.maxY - pad - glyphSize,
                           width: glyphSize, height: glyphSize)
    let bracketWidth = glyphSize * 0.06

    let camRect = glyphRect.insetBy(dx: glyphSize * 0.22, dy: glyphSize * 0.22)
    if let camera = gradientSymbol("camera", px: 512) {
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 12, color: glowColor)
        cg.draw(camera, in: camRect)
        cg.restoreGState()
        cg.draw(camera, in: camRect)
    }

    let brackets = cornerBrackets(in: glyphRect, arm: glyphSize * 0.28)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 12, color: glowColor)
    cg.addPath(brackets); cg.setStrokeColor(glowTint.cgColor)
    cg.setLineWidth(bracketWidth); cg.setLineCap(.round); cg.setLineJoin(.round); cg.strokePath()
    cg.restoreGState()
    strokeBrand(cg, brackets, width: bracketWidth, extent: content)

    // Outer hairline.
    cg.saveGState()
    cg.addPath(bezelPath)
    cg.setStrokeColor(NSColor(white: 0, alpha: 0.20).cgColor)
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
