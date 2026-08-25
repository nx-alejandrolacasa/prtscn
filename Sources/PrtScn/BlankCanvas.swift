import AppKit

/// "New Blank Canvas": a white image opened straight in the editor — a scratch
/// surface for sketching diagrams and schemas with the annotation tools.
/// Sized (in pixels) in Settings → Editor; exports at exactly that size.
@MainActor
enum BlankCanvas {
    static func open() {
        let settings = SettingsStore.shared
        guard let image = whiteImage(width: settings.canvasWidth,
                                     height: settings.canvasHeight) else { return }

        // The editor takes ownership of the temp file (works on it, deletes it
        // on close), exactly like a capture's.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prtscn-canvas-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return }

        // Scale 1: one canvas pixel per logical point, so the configured size
        // is both what the window shows at 100% and what the PNG exports.
        EditorController.shared.show(imageURL: url, captureScale: 1)
    }

    private static func whiteImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
