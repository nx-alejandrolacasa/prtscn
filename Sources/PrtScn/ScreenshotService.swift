import AppKit
// @preconcurrency: SCShareableContent isn't Sendable, which trips Swift 6's
// strict concurrency on newer toolchains (e.g. the Xcode 16 CI runner) when its
// result crosses an actor boundary. The value never leaves the main actor here,
// so downgrade those errors to warnings.
@preconcurrency import ScreenCaptureKit
import Vision
import os

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "ScreenshotService")

/// Runs captures via the macOS `screencapture` CLI and performs the
/// post-capture actions (save / copy / edit).
///
/// `@MainActor` keeps everything on the main thread (where menu actions and UI
/// live) and satisfies Swift 6 concurrency for the shared singleton.
@MainActor
final class ScreenshotService {
    static let shared = ScreenshotService()

    private init() {}

    /// True while a `screencapture` invocation is running. Region/window
    /// selections stay up until the user clicks or Escapes, so a re-fired
    /// hotkey would stack a second crosshair on top of the first.
    private var captureInFlight = false

    // MARK: - Capture

    /// Kicks off a capture. Fire-and-forget from the menu; the real work runs
    /// in an async task so we never block the main thread while the user is
    /// dragging out an interactive selection.
    func capture(_ mode: CaptureMode) {
        // Fixed size runs its own prompt → overlay flow; the overlay calls
        // back into `captureRect` with the clicked rectangle. Re-firing the
        // hotkey while the overlay is up cancels it (acts as a toggle).
        if mode == .fixedSize {
            if FixedSizeOverlay.shared.isActive {
                FixedSizeOverlay.shared.cancel()
            } else {
                FixedSizePrompt.shared.show()
            }
            return
        }
        // Scrolling runs its own overlay → scroll-and-stitch flow; same
        // toggle semantics as fixed size.
        if mode == .scrolling {
            if ScrollCaptureController.shared.isActive {
                ScrollCaptureController.shared.cancel()
            } else {
                ScrollCaptureController.shared.begin()
            }
            return
        }
        // Region/window/full-screen shell out to `screencapture` directly;
        // ignore repeat presses while one is still running (see captureInFlight).
        guard !captureInFlight else { return }
        captureInFlight = true
        Task {
            await performCapture(mode)
            captureInFlight = false
        }
    }

    /// Captures an exact screen rectangle, as reported by the fixed-size
    /// overlay in Cocoa screen coordinates (bottom-left origin).
    func captureRect(_ rect: CGRect) {
        // screencapture -R wants top-left-origin global coordinates, measured
        // down from the top of the primary display (`screens[0]`).
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let flipped = CGRect(x: rect.minX, y: primaryTop - rect.maxY,
                             width: rect.width, height: rect.height)
        Task { await performCapture(.fixedSize, rect: flipped) }
    }

    private func performCapture(_ mode: CaptureMode, rect: CGRect? = nil) async {
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
        // A pixel-grid-aligned rect lands on half points on Retina, and
        // screencapture rounds fractional rects in point space on its own terms
        // (each edge independently) — the output drifts by ±1–2 px depending on
        // where the cursor happened to land. So request the covering whole-point
        // rect and crop back to the exact requested pixels afterwards.
        var cropTarget: CGRect?
        if let rect {
            let outer = rect.integral
            if outer != rect { cropTarget = rect }
            let coordinates = [outer.minX, outer.minY, outer.width, outer.height]
                .map { String(Int($0)) }
            arguments += ["-R", coordinates.joined(separator: ",")]
        }
        if !SettingsStore.shared.shutterSound { arguments.append("-x") }
        // Only full-screen captures include the pointer: the interactive modes
        // ignore the flag anyway, and a fixed-size shot would always have the
        // arrow dead center (it sits where the user just clicked).
        if SettingsStore.shared.includePointer, mode == .fullScreen { arguments.append("-C") }

        let succeeded = await Self.runScreencapture(arguments: arguments + [tmp.path])
        let exists = FileManager.default.fileExists(atPath: tmp.path)
        log.info("capture \(mode.rawValue, privacy: .public) — succeeded=\(succeeded), fileExists=\(exists)")

        // On Esc/cancel, screencapture still exits 0 but writes no file — so we
        // check the file actually exists before showing a preview.
        guard succeeded, exists else { return }

        // Flash the menu-bar icon: feedback that survives a missed preview
        // (eyes elsewhere) or a silenced shutter sound.
        MenuBarState.shared.flashCaptureFeedback()

        // Measure the capture's backing scale now, from the pristine PNG — the
        // crop/composite steps below rewrite the file at 72 DPI, which would
        // lose it.
        let captureScale = Self.captureScale(of: tmp)

        // Trim the whole-point capture down to the exact fixed-size rect.
        if let cropTarget {
            Self.cropToRequestedRect(at: tmp, target: cropTarget, scale: captureScale)
        }

        // Composite based on what was actually captured, not the requested mode:
        // a Space-switched region capture is a genuine window shot and should be
        // framed just like one. `compositeWindowBackground` no-ops on opaque
        // (region/full-screen) shots.
        //
        // Keep the pre-composite capture in memory: Pin displays the bare
        // window (trimmed), not the framed margins/solid/wallpaper version.
        var pristine: NSImage?
        if windowBackground.needsComposite {
            pristine = NSImage(contentsOf: tmp)
            await compositeWindowBackground(at: tmp, background: windowBackground)
        }

        PreviewController.shared.show(imageURL: tmp, captureScale: captureScale,
                                      pristineImage: pristine)
    }

    /// The backing scale the capture was taken at: pixel width ÷ logical (point)
    /// width, read from the screencapture PNG's DPI. 2 on Retina, 1 otherwise.
    /// If the PNG can't be re-read, fall back to the main display's scale
    /// rather than assuming Retina — measure labels divide by this, so a wrong
    /// guess would silently skew every reading.
    private static func captureScale(of url: URL) -> CGFloat {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        let pixelsWide = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        return max((CGFloat(pixelsWide) / image.size.width).rounded(), 1)
    }

    /// Crops the capture back to the exact requested rectangle after an
    /// outward-rounded `screencapture -R`. `target` is the requested rect in
    /// top-left-origin points; the file on disk covers `target.integral`, so
    /// the offset between the two — times the backing scale — locates the
    /// wanted pixels. Overwrites the temp PNG in place.
    private static func cropToRequestedRect(at url: URL, target: CGRect, scale: CGFloat) {
        guard let image = NSImage(contentsOf: url),
              let capture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let outer = target.integral
        // CGImage.cropping uses top-left-origin pixel coordinates — same
        // orientation as the screencapture rects, so no flip here.
        let crop = CGRect(
            x: ((target.minX - outer.minX) * scale).rounded(),
            y: ((target.minY - outer.minY) * scale).rounded(),
            width: (target.width * scale).rounded(),
            height: (target.height * scale).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: capture.width, height: capture.height))
        guard !crop.isEmpty, crop.size != CGSize(width: capture.width, height: capture.height),
              let cropped = capture.cropping(to: crop)
        else { return }
        // Keep the capture's DPI tag (144 on Retina): a fresh rep defaults to
        // 72, which would make cropped shots report a different density than
        // uncropped ones from the same feature.
        let rep = NSBitmapImageRep(cgImage: cropped)
        rep.size = NSSize(width: CGFloat(cropped.width) / scale,
                          height: CGFloat(cropped.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
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

            // Finder's desktop-icons layer sits one level above the wallpaper
            // itself, so `excludingDesktopWindows` above strips it out of
            // `content.windows` along with the wallpaper — it was never in
            // our exclude list and kept showing through. Fetch it separately
            // (desktop windows included this time) and exclude just that
            // layer by window level, leaving the wallpaper's own lower level
            // alone so the stream doesn't fail to start.
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            let fullContent = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let desktopIcons = fullContent.windows.filter { $0.windowLayer == iconLevel }

            let filter = SCContentFilter(display: display,
                                         excludingWindows: content.windows + desktopIcons)
            let config = SCStreamConfiguration()
            // Derive the capture size from the filter (point rect × pixel scale).
            // Using the display's point size mismatches the stream and triggers
            // the -3811 "failed to start" error.
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log.error("wallpaper capture failed: \(String(describing: error), privacy: .public)")
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
                log.error("screencapture failed to launch: \(String(describing: error), privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Actions on a captured image

    /// Saves the temp capture to the save folder, honoring the configured save
    /// resolution: native pixels, downscaled to standard resolution, or both
    /// files (the native one gets an `@2x`-style suffix derived from the actual
    /// scale). Returns the saved URL — the downscaled file when both are written.
    ///
    /// `captureScale` must be the scale measured at capture time: the
    /// window-background composite rewrites the temp PNG at 72 DPI, so
    /// re-reading the file's DPI here would wrongly report 1x.
    @discardableResult
    func save(_ url: URL, captureScale: CGFloat) -> URL? {
        // Use the configured save folder, falling back to Desktop if it's
        // missing or no longer a directory.
        var folder = URL(fileURLWithPath: SettingsStore.shared.saveFolderPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        let valid = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        if !(valid && isDirectory.boolValue) {
            folder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        let baseName = "\(SettingsStore.shared.sanitizedFilenamePrefix) \(Self.timestamp())"

        // A 1x-flavored save needs the downscaled pixels up front; if the
        // capture is already 1x (or the resample fails), fall back to a plain
        // native save rather than losing the shot.
        var downscaled: Data?
        if SettingsStore.shared.saveResolution != .native,
           let small = Self.downscaledImage(at: url, dividedBy: captureScale) {
            downscaled = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
        }

        // Same-second saves collide on the timestamped name; suffix with
        // " (2)", " (3)"… until the name — and, for Both, its native `@Nx`
        // companion — is free, so a quick burst never throws away a shot.
        let savesNativeCopy = downscaled != nil && SettingsStore.shared.saveResolution == .both
        func taken(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).png").path)
                || (savesNativeCopy && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("\(name)@\(Int(captureScale))x.png").path))
        }
        var name = baseName
        var counter = 2
        while taken(name) {
            name = "\(baseName) (\(counter))"
            counter += 1
        }

        let destination = folder.appendingPathComponent("\(name).png")
        do {
            guard let downscaled else {
                try FileManager.default.copyItem(at: url, to: destination)
                return destination
            }
            try downscaled.write(to: destination)
            if SettingsStore.shared.saveResolution == .both {
                try FileManager.default.copyItem(
                    at: url,
                    to: folder.appendingPathComponent("\(name)@\(Int(captureScale))x.png"))
            }
            return destination
        } catch {
            log.error("save failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func copyToClipboard(_ url: URL, captureScale: CGFloat) {
        // Honor the configured copy resolution: a pixel-sized (72 DPI) NSImage
        // so paste targets treat the downscaled capture as a true 1x image.
        if SettingsStore.shared.copyResolution == .downscaled,
           let small = Self.downscaledImage(at: url, dividedBy: captureScale) {
            let image = NSImage(cgImage: small,
                                size: NSSize(width: small.width, height: small.height))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            return
        }
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// The capture resampled from Retina down to 1x pixels — high-quality
    /// CPU-only Core Graphics. Returns `nil` when there's nothing to downscale
    /// (already 1x) or the file can't be read; callers fall back to native.
    private static func downscaledImage(at url: URL, dividedBy scale: CGFloat) -> CGImage? {
        guard scale > 1,
              let image = NSImage(contentsOf: url),
              let capture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let width = max(Int((CGFloat(capture.width) / scale).rounded()), 1)
        let height = max(Int((CGFloat(capture.height) / scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(capture, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Runs on-device OCR (Apple's Vision framework) over the captured image and
    /// puts the recognized text on the clipboard. No network, no dependencies —
    /// this is the same engine that powers Live Text. Operates on the in-memory
    /// image so it's unaffected by the temp file being cleaned up afterwards.
    /// Fire-and-forget: the recognition itself runs off the main actor.
    func copyText(in image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            log.error("OCR: could not rasterize image")
            return
        }
        Task {
            guard let text = await Self.recognizeText(in: cgImage) else {
                log.info("OCR: no text recognized")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Recognizes text in `image`, returning the lines joined with newlines, or
    /// `nil` if Vision finds nothing. The Swift Vision API performs the request
    /// on its own executor, so awaiting it suspends — rather than blocks — the
    /// main actor while an accurate pass chews on a large capture.
    private static func recognizeText(in image: CGImage) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            let observations = try await request.perform(on: image)
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            log.error("OCR failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Removes a temp capture once we're done with it.
    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        // POSIX locale pins the fixed format: without it, a user's 12/24-hour
        // override can inject "AM/PM" into filenames (Apple QA1480).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
