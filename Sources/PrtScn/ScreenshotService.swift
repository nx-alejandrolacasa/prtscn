import AppKit
// @preconcurrency: SCShareableContent isn't Sendable, which trips Swift 6's
// strict concurrency on newer toolchains (e.g. the Xcode 16 CI runner) when its
// result crosses an actor boundary. The value never leaves the main actor here,
// so downgrade those errors to warnings.
@preconcurrency import ScreenCaptureKit
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
        //
        // A region capture (`-i`) lets the user press Space to switch to window
        // selection, so the window-background flags must apply there too — not
        // just to the dedicated Window mode.
        let windowBackground = SettingsStore.shared.windowBackground
        var arguments = mode.screencaptureArgs
        if mode == .window || mode == .region {
            arguments += windowBackground.extraCaptureArgs
        }

        let succeeded = await Self.runScreencapture(arguments: arguments + [tmp.path])
        let exists = FileManager.default.fileExists(atPath: tmp.path)
        NSLog("[PrtScn] capture \(mode) — succeeded=\(succeeded), fileExists=\(exists)")

        // On Esc/cancel, screencapture still exits 0 but writes no file — so we
        // check the file actually exists before showing a preview.
        guard succeeded, exists else { return }

        // Measure the capture's backing scale now, from the pristine PNG — the
        // composite step below rewrites the file at 72 DPI, which would lose it.
        let captureScale = Self.captureScale(of: tmp)

        // Composite based on what was actually captured, not the requested mode:
        // a Space-switched region capture is a genuine window shot and should be
        // framed just like one. `compositeWindowBackground` no-ops on opaque
        // (region/full-screen) shots.
        if windowBackground.needsComposite {
            await compositeWindowBackground(at: tmp, background: windowBackground)
        }

        PreviewController.shared.show(imageURL: tmp, captureScale: captureScale)
    }

    /// The backing scale the capture was taken at: pixel width ÷ logical (point)
    /// width, read from the screencapture PNG's DPI. 2 on Retina, 1 otherwise.
    private static func captureScale(of url: URL) -> CGFloat {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return 2 }
        let pixelsWide = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        return max((CGFloat(pixelsWide) / image.size.width).rounded(), 1)
    }

    /// Draws the chosen background behind a window capture (which is a window +
    /// drop shadow on a transparent surround) and overwrites the temp PNG with
    /// the result. All CoreGraphics — no GPU, no dependencies.
    private func compositeWindowBackground(at url: URL, background: WindowBackground) async {
        guard let image = NSImage(contentsOf: url),
              let capture = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              capture.width > 0, capture.height > 0 else { return }

        // Only window shots have a transparent surround; region rectangles and
        // full-screen grabs are fully opaque, so there's nothing to frame.
        guard Self.looksLikeWindowShot(capture) else { return }

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
            if let wallpaper = await Self.currentWallpaperImage() {
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

    /// Heuristic: a window capture has a transparent surround (drop shadow and/or
    /// rounded corners), whereas region rectangles and full-screen grabs are
    /// fully opaque. We downscale to 32×32 and check the corner pixels' alpha —
    /// cheap and robust against a single opaque corner.
    private static func looksLikeWindowShot(_ image: CGImage) -> Bool {
        let side = 32
        // Start fully transparent: source-over drawing then leaves the surround
        // transparent (window shot) or fully opaque (region/full-screen).
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &data, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * side + x) * 4 + 3] }
        let corners = [alpha(0, 0), alpha(side - 1, 0), alpha(0, side - 1), alpha(side - 1, side - 1)]
        return corners.contains { $0 < 250 }
    }

    /// The current desktop wallpaper for the main display, as a `CGImage`.
    ///
    /// We capture the live desktop with ScreenCaptureKit (excluding every
    /// window, so only the wallpaper remains) rather than reading the picture
    /// file: modern macOS dynamic/HEIC wallpapers can't be loaded reliably from
    /// `NSWorkspace.desktopImageURL`. This reuses the Screen Recording
    /// permission the app already has. Falls back to the picture file if the
    /// capture is unavailable.
    private static func currentWallpaperImage() async -> CGImage? {
        do {
            // Get app windows only (desktop/wallpaper windows are kept out of the
            // list). We then exclude these app windows from the capture, leaving
            // the display's wallpaper backstop — excluding *all* windows
            // (including the wallpaper window) makes the stream fail to start.
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            let main = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == main })
                ?? content.displays.first else { return fallbackWallpaperImage() }

            let filter = SCContentFilter(display: display, excludingWindows: content.windows)
            let config = SCStreamConfiguration()
            // Derive the capture size from the filter (point rect × pixel scale).
            // Using the display's point size mismatches the stream and triggers
            // the -3811 "failed to start" error.
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("[PrtScn] wallpaper capture failed: \(error)")
            return fallbackWallpaperImage()
        }
    }

    /// Last-resort wallpaper: read the desktop picture file directly.
    private static func fallbackWallpaperImage() -> CGImage? {
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
