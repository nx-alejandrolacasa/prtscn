import AppKit
import ImageIO
import UniformTypeIdentifiers

// PrtScn app icon, keycap edition: turns the photographic keycap in
// assets/keycap-icon.png into both icon representations the build consumes.
//
//   • AppIcon.iconset / AppIcon-preview.png — the flat icon: the keycap cut out
//     of its white backdrop, set on Apple's 824pt grid with a soft drop shadow.
//     `iconutil` turns the iconset into Resources/AppIcon.icns.
//   • Resources/AppIcon.icon — an Icon Composer document with the keycap as one
//     full-bleed layer. macOS 26 masks it to its own squircle.
//
// Usage (from the repo root):
//
//   swiftc tools/KeycapIcon.swift -o /tmp/keycapicon && /tmp/keycapicon
//   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
//   ./build.sh

private let sourcePath = "assets/keycap-icon.png"
private let canvas = 1024

/// How much the keycap is enlarged in the layered icon. The keycap's corners
/// are rounder than the macOS 26 icon mask, so at 1:1 the mask would reach past
/// the plastic into the backdrop. Measured against the mask `actool` renders:
/// 1.025 is the exact fit, 1.04 leaves ~6px of slack on the 1024 canvas.
private let layeredScale: CGFloat = 1.04

/// Apple's icon grid: the tile is 824pt of the 1024pt canvas (what `actool`
/// renders for the layered icon too), leaving room for the shadow.
private let flatTile: CGFloat = 824

/// A backdrop pixel is near-white in every channel. The keycap's own highlights
/// are cream, so their blue channel stays well under this.
private let backdropThreshold: UInt8 = 238

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

private func makeContext(_ size: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext {
    let cg = CGContext(data: data, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: size * 4, space: sRGB, bitmapInfo: bitmapInfo)!
    cg.interpolationQuality = .high
    return cg
}

// MARK: - Cut-out

/// The keycap with its white backdrop removed, plus the plastic's average
/// colour (used wherever something has to sit behind the keycap).
private func cutOut(_ source: CGImage) -> (image: CGImage, average: NSColor) {
    let w = canvas, h = canvas
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cg = makeContext(w, data: &px)
    cg.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Flood-fill the backdrop inwards from the four corners, so near-white
    // pixels *inside* the keycap (there are none today, but a glossier render
    // might have some) are never mistaken for it.
    var backdrop = [Bool](repeating: false, count: w * h)
    var stack = [0, w - 1, (h - 1) * w, h * w - 1]
    while let i = stack.popLast() {
        if backdrop[i] || min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) <= backdropThreshold { continue }
        backdrop[i] = true
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }
        if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }
        if y < h - 1 { stack.append(i + w) }
    }

    // Coverage: pull the edge in by one pixel (the outermost ring is blended
    // with the white backdrop and would read as a halo), then soften it.
    func pass(_ input: [Float], _ combine: (Float, Float) -> Float, _ finish: (Float) -> Float) -> [Float] {
        var out = input
        for y in 0..<h {
            for x in 0..<w {
                var acc = input[y * w + x]
                var first = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = min(max(x + dx, 0), w - 1), yy = min(max(y + dy, 0), h - 1)
                        let v = input[yy * w + xx]
                        acc = first ? v : combine(acc, v)
                        first = false
                    }
                }
                out[y * w + x] = finish(acc)
            }
        }
        return out
    }
    var alpha = backdrop.map { $0 ? Float(0) : Float(1) }
    alpha = pass(alpha, min) { $0 }             // erode
    alpha = pass(alpha, +) { $0 / 9 }           // box blur

    var sum = (r: 0.0, g: 0.0, b: 0.0), count = 0.0
    for i in 0..<(w * h) {
        let a = alpha[i]
        if a == 1 {
            sum.r += Double(px[i * 4]); sum.g += Double(px[i * 4 + 1]); sum.b += Double(px[i * 4 + 2])
            count += 1
        }
        // Premultiplied RGBA.
        px[i * 4] = UInt8(Float(px[i * 4]) * a)
        px[i * 4 + 1] = UInt8(Float(px[i * 4 + 1]) * a)
        px[i * 4 + 2] = UInt8(Float(px[i * 4 + 2]) * a)
        px[i * 4 + 3] = UInt8(255 * a)
    }
    let average = NSColor(srgbRed: sum.r / count / 255, green: sum.g / count / 255,
                          blue: sum.b / count / 255, alpha: 1)
    return (cg.makeImage()!, average)
}

// MARK: - Renders

/// Flat icon: the keycap's own silhouette on the 824pt grid, with a drop shadow.
private func renderFlat(_ keycap: CGImage) -> CGImage {
    let cg = makeContext(canvas)
    let inset = (CGFloat(canvas) - flatTile) / 2
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
                 color: NSColor(white: 0, alpha: 0.30).cgColor)
    cg.draw(keycap, in: CGRect(x: inset, y: inset, width: flatTile, height: flatTile))
    return cg.makeImage()!
}

/// Layered icon's one layer: the keycap enlarged past the canvas edge so the
/// system mask lands on plastic everywhere, over the plastic's average colour.
private func renderLayer(_ keycap: CGImage, backing: NSColor) -> CGImage {
    let cg = makeContext(canvas)
    cg.setFillColor(backing.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let side = CGFloat(canvas) * layeredScale
    let origin = (CGFloat(canvas) - side) / 2
    cg.draw(keycap, in: CGRect(x: origin, y: origin, width: side, height: side))
    return cg.makeImage()!
}

private func resized(_ image: CGImage, to size: Int) -> CGImage {
    if size == image.width { return image }
    let cg = makeContext(size)
    cg.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return cg.makeImage()!
}

private func writePNG(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(path)") }
}

// MARK: - Icon Composer document

/// `icon.json`, encoded so it matches Icon Composer's own on-disk format
/// (alphabetical keys, two-space indent, `" : "` separators, no trailing newline).
private struct IconDocument: Encodable {
    struct Fill: Encodable { let solid: String }
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
        let specular: Bool
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

private func iconColor(_ c: NSColor) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,%.5f",
           c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
}

private let layerAssetName = "keycap.png"

private func writeIconComposerPackage(at path: String, layer: CGImage, backing: NSColor) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: path)
    let assets = root.appendingPathComponent("Assets")
    try! fm.createDirectory(at: assets, withIntermediateDirectories: true)

    // The keycap is a photograph that already carries its own lighting, bevel
    // and shadows — so no Liquid Glass, no specular rim and no group shadow on
    // top of it, and (as always here) translucency explicitly off.
    let doc = IconDocument(
        fill: .init(solid: iconColor(backing)),
        groups: [.init(layers: [.init(glass: false, imageName: layerAssetName, name: "Keycap")],
                       shadow: .init(kind: "none", opacity: 0.5),
                       specular: false,
                       translucency: .init(enabled: false, value: 0.5))],
        supportedPlatforms: .init(squares: "shared"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! encoder.encode(doc).write(to: root.appendingPathComponent("icon.json"))
    writePNG(layer, to: assets.appendingPathComponent(layerAssetName).path)

    let extras = Set((try? fm.contentsOfDirectory(atPath: assets.path)) ?? [])
        .subtracting([layerAssetName]).filter { !$0.hasPrefix(".") }.sorted()
    if !extras.isEmpty {
        print("note: \(path)/Assets has files this icon doesn't use: \(extras.joined(separator: ", "))")
    }
    print("Wrote \(path)")
}

// MARK: - Main

guard let data = FileManager.default.contents(atPath: sourcePath),
      let source = NSBitmapImageRep(data: data)?.cgImage else {
    fatalError("could not read \(sourcePath) — run from the repo root")
}

let (keycap, plastic) = cutOut(source)
let flat = renderFlat(keycap)

let iconset = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let targets: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in targets {
    writePNG(resized(flat, to: size), to: "\(iconset)/\(name)")
}
writePNG(flat, to: "AppIcon-preview.png")
print("Wrote \(iconset) and AppIcon-preview.png")

writeIconComposerPackage(at: "Resources/AppIcon.icon",
                         layer: renderLayer(keycap, backing: plastic), backing: plastic)
