import AppKit
import Vision

/// Runs captures via the macOS `screencapture` CLI and performs the
/// post-capture actions (save / copy / edit).
///
/// `@MainActor` keeps everything on the main thread (where menu actions and UI
/// live) and satisfies Swift 6 concurrency for the shared singleton.
@MainActor
final class ScreenshotService {
    static let shared = ScreenshotService()

    private init() {}

    // MARK: - Capture

    /// Kicks off a capture. Fire-and-forget from the menu; the real work runs
    /// in an async task so we never block the main thread while the user is
    /// dragging out an interactive selection.
    func capture(_ mode: CaptureMode) {
        Task { await performCapture(mode) }
    }

    private func performCapture(_ mode: CaptureMode) async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prtscn-\(UUID().uuidString).png")

        // The window-background choice can add capture flags (Trim Shadow) and/or
        // require a composite afterwards (Solid color / Desktop background).
        let windowBackground = SettingsStore.shared.windowBackground
        var arguments = mode.screencaptureArgs
        if mode == .window {
            arguments += windowBackground.extraCaptureArgs
        }

        let succeeded = await Self.runScreencapture(arguments: arguments + [tmp.path])
        let exists = FileManager.default.fileExists(atPath: tmp.path)
        NSLog("[PrtScn] capture \(mode) — succeeded=\(succeeded), fileExists=\(exists)")

        // On Esc/cancel, screencapture still exits 0 but writes no file — so we
        // check the file actually exists before showing a preview.
        guard succeeded, exists else { return }

        if mode == .window && windowBackground.needsComposite {
            compositeWindowBackground(at: tmp, background: windowBackground)
        }

        PreviewController.shared.show(imageURL: tmp)
    }

    /// Draws the chosen background behind a window capture (which is a window +
    /// drop shadow on a transparent surround) and overwrites the temp PNG with
    /// the result. All CoreGraphics — no GPU, no dependencies.
    private func compositeWindowBackground(at url: URL, background: WindowBackground) {
        guard let image = NSImage(contentsOf: url),
              let capture = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              capture.width > 0, capture.height > 0 else { return }

        // Add breathing room around the window so the background is actually
        // visible as a margin (≈6% of the longest edge, clamped). The capture is
        // retina, so these are pixel values.
        let padding = min(max(Int((Double(max(capture.width, capture.height)) * 0.06).rounded()), 56), 160)
        let canvasWidth = capture.width + padding * 2
        let canvasHeight = capture.height + padding * 2
        let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let captureRect = CGRect(x: padding, y: padding, width: capture.width, height: capture.height)

        guard let context = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // 1. Paint the background across the whole canvas.
        switch background {
        case .solidColor:
            context.setFillColor(NSColor(SettingsStore.shared.windowBackgroundColor).cgColor)
            context.fill(canvas)
        case .wallpaper:
            if let wallpaper = Self.currentWallpaperImage() {
                context.draw(wallpaper, in: Self.aspectFillRect(of: wallpaper, in: canvas))
            } else {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(canvas)
            }
        default:
            return
        }

        // 2. Composite the window + shadow on top, inset by the padding.
        context.draw(capture, in: captureRect)

        guard let composed = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    /// The current desktop picture for the main display, as a `CGImage`.
    private static func currentWallpaperImage() -> CGImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return cgImage
    }

    /// A rect that scales `image` to fill `bounds` while preserving aspect ratio
    /// (centered, cropping the overflow) — the classic "aspect fill".
    private static func aspectFillRect(of image: CGImage, in bounds: CGRect) -> CGRect {
        let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// Launches `screencapture` and resumes once it exits. Uses a continuation
    /// + `terminationHandler` so the `await` suspends (rather than blocks) the
    /// main actor while the interactive selection is in progress.
    private static func runScreencapture(arguments: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                NSLog("[PrtScn] screencapture failed to launch: \(error)")
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Actions on a captured image

    /// Saves a copy of the temp capture to the save folder (Desktop for now;
    /// configurable in a later slice). Returns the saved URL.
    @discardableResult
    func save(_ url: URL) -> URL? {
        // Use the configured save folder, falling back to Desktop if it's
        // missing or no longer a directory.
        var folder = URL(fileURLWithPath: SettingsStore.shared.saveFolderPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        let valid = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        if !(valid && isDirectory.boolValue) {
            folder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        let destination = folder.appendingPathComponent("PrtScn \(Self.timestamp()).png")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            NSLog("[PrtScn] save failed: \(error)")
            return nil
        }
    }

    func copyToClipboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// Runs on-device OCR (Apple's Vision framework) over the captured image and
    /// puts the recognized text on the clipboard. No network, no dependencies —
    /// this is the same engine that powers Live Text. Operates on the in-memory
    /// image so it's unaffected by the temp file being cleaned up afterwards.
    func copyText(in image: NSImage) {
        guard let text = Self.recognizeText(in: image) else {
            NSLog("[PrtScn] OCR: no text recognized")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Recognizes text in `image`, returning the lines joined with newlines, or
    /// `nil` if Vision finds nothing.
    private static func recognizeText(in image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[PrtScn] OCR failed: \(error)")
            return nil
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Opens the capture in Preview.app for markup/editing.
    func edit(_ url: URL) {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        NSWorkspace.shared.open([url], withApplicationAt: preview,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Removes a temp capture once we're done with it.
    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
