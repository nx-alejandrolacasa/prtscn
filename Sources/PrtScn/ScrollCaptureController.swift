import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Drives the scrolling capture: region selection → auto-scroll the content
/// underneath (synthetic scroll-wheel events, which is why this mode — alone
/// in the app — needs the Accessibility permission) → capture a frame per
/// step via ScreenCaptureKit → stitch → hand the tall PNG to the preview.
///
/// While capturing: click anywhere or Return finishes and keeps the stitch,
/// Esc cancels and discards. Scroll events are routed by the window server to
/// whatever sits under the *pointer*, so the pointer is warped to the region
/// center for the duration and restored afterwards.
@MainActor
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private enum Phase { case idle, selecting, capturing }
    private var phase: Phase = .idle

    var isActive: Bool { phase != .idle }

    /// Safety fuse on the number of scroll steps — a pure runaway guard, not
    /// a working limit. Apps that advance in small quanta (terminals scroll
    /// by whole lines) need many more steps to reach the height cap than a
    /// browser does; normal termination is bottom/lost-track/cap.
    private static let maxFrames = 500
    /// Scroll step as a fraction of the region height. Half-height steps
    /// leave half the frame as shared texture at every seam — repetitive
    /// content (terminal transcripts) needs that much context to
    /// disambiguate; browsers were fine even at 0.6.
    private static let scrollStepFraction: CGFloat = 0.5
    /// Each scroll step is animated as a burst of small wheel deltas at
    /// roughly 60 Hz — the content glides instead of teleporting. The
    /// stitcher measures actual movement, so the glide costs nothing in
    /// accuracy.
    private static let glideTicks = 15
    private static let glideTickDelay: Duration = .milliseconds(16)
    /// Wait after the glide for any residual app-side smoothing to settle
    /// before capturing the frame (the glide already ends gently, so this
    /// can be much shorter than a single-jump scroll would need).
    private static let settleDelay: Duration = .milliseconds(200)
    /// Between the paired captures of the settle check, and before each
    /// retake while the content is still moving.
    private static let settleRetryDelay: Duration = .milliseconds(100)
    /// Retakes before giving up and stitching the frame as-is (endless
    /// animations never settle; the trimmed matching absorbs them).
    private static let maxSettleRetries = 5
    /// Beat between the selection overlay leaving the screen and frame 0, so
    /// the dimming never shows up in the stitch (mirrors FixedSizeOverlay).
    private static let overlayDismissDelay: Duration = .milliseconds(150)

    private var stitcher: ScrollStitcher?
    private var scale: CGFloat = 2
    private var captureTask: Task<Void, Never>?
    private var hud: NSPanel?
    private let hudModel = ScrollCaptureHUDModel()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var savedPointer: CGPoint?

    private init() {}

    func begin() {
        guard phase == .idle else { return }
        // Claim the phase before the permission check: its NSAlert runs a
        // nested run loop, so a re-fired hotkey lands mid-modal — the toggle
        // must see isActive == true instead of stacking a second alert.
        phase = .selecting
        guard ensureAccessibility() else {
            phase = .idle
            return
        }
        ScrollCaptureOverlay.shared.begin(
            onSelect: { [weak self] rect, screen, scrollUp in
                self?.startCapture(region: rect, screen: screen,
                                   direction: scrollUp ? .up : .down)
            },
            onCancel: { [weak self] in
                if self?.phase == .selecting { self?.phase = .idle }
            }
        )
    }

    func cancel() {
        switch phase {
        case .idle:
            return
        case .selecting:
            // Reset the phase ourselves — during the permission alert the
            // overlay isn't up yet, so its onCancel wouldn't fire.
            phase = .idle
            ScrollCaptureOverlay.shared.cancel()
        case .capturing:
            endCapture()
            stitcher = nil
        }
    }

    /// Shared teardown for both outcomes of a running capture; the caller
    /// decides what happens to `stitcher` (discard vs. produce the image).
    private func endCapture() {
        phase = .idle
        captureTask?.cancel()
        captureTask = nil
        teardownCapture()
    }

    // MARK: - Accessibility

    /// Scrolling capture posts scroll-wheel events into other apps, which
    /// macOS only allows for Accessibility-trusted processes. Check silently;
    /// when untrusted, register the app in the Accessibility list (without
    /// the stock system prompt) and explain in our own words.
    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // The literal value of `kAXTrustedCheckOptionPrompt`, which Swift 6
        // rejects as a non-Sendable global.
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Scrolling Capture needs Accessibility access"
        alert.informativeText = """
            PrtScn scrolls the page for you by sending scroll events, and \
            macOS only allows that for apps with Accessibility permission.

            Enable PrtScn in System Settings → Privacy & Security → \
            Accessibility, then try again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - Capture loop

    private func startCapture(region: CGRect, screen: NSScreen,
                              direction: ScrollStitcher.Direction) {
        phase = .capturing
        captureTask = Task { [weak self] in
            await self?.runCapture(region: region, screen: screen, direction: direction)
        }
    }

    private func runCapture(region: CGRect, screen: NSScreen,
                            direction: ScrollStitcher.Direction) async {
        try? await Task.sleep(for: Self.overlayDismissDelay)
        guard phase == .capturing else { return }

        guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value,
              let content = try? await SCShareableContent.excludingDesktopWindows(
                  false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            cancel()
            return
        }
        guard phase == .capturing else { return }

        // Exclude our own windows so a lingering preview card or pin inside
        // the region can never contaminate the frames (the sourceRect crop
        // already keeps the HUD out — it sits outside the region).
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: ours)
        scale = CGFloat(filter.pointPixelScale)

        // sourceRect is display-local, top-left origin, in points; the output
        // size must be the same rect in *pixels* or SCK fails with -3811.
        let local = CGRect(x: region.minX - screen.frame.minX,
                           y: screen.frame.maxY - region.maxY,
                           width: region.width, height: region.height)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        // Rounded, not truncated: a floating-point hair below the true pixel
        // count (799.999…) would desync width/height from sourceRect × scale
        // and trip SCK's -3811 size check.
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.showsCursor = false   // the warped pointer sits mid-region

        showHUD(near: region, on: screen)
        installMonitors()
        savedPointer = CGEvent(source: nil)?.location
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: region.midX, y: primaryTop - region.midY))
        CGAssociateMouseAndMouseCursorPosition(1)

        // Snapshotted per capture — the user-set cap (Settings → Capture,
        // store-clamped below CG's context limit) shouldn't shift mid-run.
        let maxHeightPx = SettingsStore.shared.scrollMaxHeight
        guard let first = try? await SCScreenshotManager.captureImage(
                  contentFilter: filter, configuration: config),
              phase == .capturing,
              let stitcher = ScrollStitcher(firstFrame: first, maxHeightPx: maxHeightPx,
                                            direction: direction)
        else {
            Self.logDiagnostic("scrolling capture aborted — first frame failed")
            cancel()
            return
        }
        self.stitcher = stitcher
        hudModel.capturedPx = stitcher.stitchedHeightPx

        // The ⌘ of a ⌘-drag is inevitably still down for a beat after
        // mouse-up — and scroll events delivered while it's physically held
        // get treated as ⌘+scroll (zoom/no-op) by the target app, which
        // reads as "content end" after two still frames. Hold fire until
        // it's released (bounded, in case ⌘ is genuinely being held).
        var waitedForCommand: Duration = .zero
        while NSEvent.modifierFlags.contains(.command),
              phase == .capturing, !Task.isCancelled,
              waitedForCommand < .seconds(5) {
            try? await Task.sleep(for: .milliseconds(50))
            waitedForCommand += .milliseconds(50)
        }
        guard phase == .capturing, !Task.isCancelled else { return }

        let stepPoints = Int(region.height * Self.scrollStepFraction)
        let expectedAdvancePx = CGFloat(stepPoints) * scale
        var consecutiveNoChange = 0
        var frames = 1
        // Apps that round every wheel event up to whole lines (terminals)
        // multiply the glide's many small deltas into huge jumps that leave
        // no overlap to stitch. When a step overshoots, halve the tick count
        // for the rest of the run — quantizers degrade toward one event per
        // step (a single rounding); browsers never trigger this.
        var glideTicks = Self.glideTicks

        while phase == .capturing, !Task.isCancelled, frames < Self.maxFrames {
            let heightBefore = stitcher.stitchedHeightPx
            await glideScroll(points: stepPoints, direction: direction, ticks: glideTicks)
            try? await Task.sleep(for: Self.settleDelay)
            guard phase == .capturing, !Task.isCancelled else { return }
            guard let frame = await captureSettledFrame(filter: filter, config: config)
            else {             // display gone / permission revoked → keep partial
                finish(because: "frame capture failed")
                return
            }
            guard phase == .capturing else { return }
            frames += 1

            switch stitcher.append(frame) {
            case .advanced:
                consecutiveNoChange = 0
                hudModel.capturedPx = stitcher.stitchedHeightPx
                let advance = CGFloat(stitcher.stitchedHeightPx - heightBefore)
                if advance > expectedAdvancePx * 1.4, glideTicks > 1 {
                    glideTicks = max(1, glideTicks / 2)
                    Self.logDiagnostic("scrolling capture: step overshot "
                        + "(\(Int(advance)) px vs \(Int(expectedAdvancePx)) expected) — "
                        + "glide ticks now \(glideTicks)")
                }
                if stitcher.stitchedHeightPx >= maxHeightPx {
                    finish(because: "height cap (\(maxHeightPx) px)")
                    return
                }
            case .noChange:
                consecutiveNoChange += 1
                if consecutiveNoChange >= 3 {   // three strikes — apps can stall a beat
                    finish(because: "content end — three unchanged frames")
                    return
                }
            case .lostTrack:                    // untrackable content → keep partial
                finish(because: "lost track of the content (\(stitcher.lastMatchInfo))")
                return
            }
        }
        finish(because: "frame budget (\(Self.maxFrames))")
    }

    /// Captures a frame only once the content has come to rest: takes two
    /// captures a beat apart and retakes while they differ. A frame grabbed
    /// mid smooth-scroll (or mid elastic bounce at the page bottom) matches
    /// no resting position, and stitching it ghosts the seam.
    private func captureSettledFrame(filter: SCContentFilter,
                                     config: SCStreamConfiguration) async -> CGImage? {
        guard var frame = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }
        for _ in 0..<Self.maxSettleRetries {
            guard phase == .capturing, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: Self.settleRetryDelay)
            guard let retake = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            ) else { return frame }
            if ScrollStitcher.framesLookSettled(frame, retake) { return retake }
            frame = retake
        }
        return frame
    }

    /// Animates one scroll step as an ease-in-out burst of small deltas, so
    /// the content glides between shots instead of jumping. Cumulative
    /// rounding (target − posted) guarantees the ticks sum to exactly
    /// `points` no matter how the easing divides.
    private func glideScroll(points: Int, direction: ScrollStitcher.Direction,
                             ticks: Int) async {
        // Negative wheel deltas scroll down (reveal content below).
        let sign = direction == .down ? -1 : 1
        var posted = 0
        for tick in 1...max(1, ticks) {
            guard phase == .capturing, !Task.isCancelled else { return }
            let progress = Double(tick) / Double(max(1, ticks))
            let eased = progress < 0.5
                ? 2 * progress * progress
                : 1 - (-2 * progress + 2) * (-2 * progress + 2) / 2
            let target = Int((Double(points) * eased).rounded())
            if target > posted {
                postScroll(delta: sign * (target - posted))
                posted = target
            }
            try? await Task.sleep(for: Self.glideTickDelay)
        }
    }

    /// Pixel-unit wheel deltas are applied like precise trackpad scrolling
    /// (no line rounding, no momentum), and correctness never depends on the
    /// app honoring the amount — the stitcher measures the actual movement.
    private func postScroll(delta: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: Int32(delta),
                                  wheel2: 0, wheel3: 0) else { return }
        // A nil-source event snapshots the *physical* keyboard state into its
        // flags — with ⌘ still held from the ⌘-drag gesture, apps would see
        // ⌘+scroll (zoom!) instead of a scroll. Always post bare events.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Finish

    /// Breadcrumbs for diagnosing why a capture stopped where it did: the
    /// unified log (Console.app) plus a plain file at ~/Library/Logs/
    /// PrtScn.log, because `log show` is off-limits in sandboxed shells.
    static func logDiagnostic(_ message: String) {
        NSLog("%@", message)
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8),
              let url = FileManager.default.urls(for: .libraryDirectory,
                                                 in: .userDomainMask).first?
                  .appendingPathComponent("Logs/PrtScn.log")
        else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func finish(because reason: String = "user finished (click/Return)") {
        guard phase == .capturing else { return }
        Self.logDiagnostic("scrolling capture finished — \(reason) at \(stitcher?.stitchedHeightPx ?? 0) px")
        endCapture()
        defer { stitcher = nil }
        guard let image = stitcher?.makeFinalImage() else { return }

        // PNG-encoding a stitch this size takes long enough to feel like a
        // freeze, so it runs off the main actor; CGImage is immutable, the
        // box just vouches for it. The DPI tag makes downstream
        // save/copy/editor treat the pixels at the capture scale (same trick
        // as ScreenshotService's crop path).
        struct ImageBox: @unchecked Sendable { let image: CGImage }
        let box = ImageBox(image: image)
        let scale = self.scale
        Task.detached(priority: .userInitiated) {
            let rep = NSBitmapImageRep(cgImage: box.image)
            rep.size = NSSize(width: CGFloat(box.image.width) / scale,
                              height: CGFloat(box.image.height) / scale)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("prtscn-\(UUID().uuidString).png")
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: tmp)) != nil
            else { return }
            await MainActor.run {
                MenuBarState.shared.flashCaptureFeedback()
                PreviewController.shared.show(imageURL: tmp, captureScale: scale)
            }
        }
    }

    // MARK: - HUD + monitors

    private func showHUD(near region: CGRect, on screen: NSScreen) {
        hudModel.capturedPx = 0
        let hosting = NSHostingView(rootView: ScrollCaptureHUDView(model: hudModel))
        let size = hosting.fittingSize
        // Below the region, or above it when there's no room — never inside,
        // so it can't overlap the capture or sit under the warped pointer.
        var origin = CGPoint(x: region.midX - size.width / 2,
                             y: region.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY {
            origin.y = region.maxY + 12
        }
        origin.x = min(max(origin.x, screen.frame.minX + 8),
                       screen.frame.maxX - size.width - 8)

        let panel = ScrollCaptureHUDPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true   // must never eat the finish click
        panel.contentView = hosting
        // Key, so Esc/Return reach the local monitor while PrtScn is active
        // (the overlay's panels are gone by now and would otherwise leave no
        // key window). Clicking the target app moves keys to the global
        // monitor — which the Accessibility grant covers.
        panel.makeKeyAndOrderFront(nil)
        hud = panel
    }

    /// Esc cancels and discards, Return/Enter finishes and keeps. `true`
    /// when the key was handled (the local monitor then swallows it).
    private func handleKey(_ keyCode: UInt16) -> Bool {
        guard phase == .capturing else { return false }
        switch keyCode {
        case 53:                            // Esc
            cancel()
            return true
        case 36, 76:                        // Return / keypad Enter
            finish()
            return true
        default:
            return false
        }
    }

    private func installMonitors() {
        // Local for while PrtScn is active (the HUD holds key), global for
        // when a click has moved focus to the target app — the Accessibility
        // grant covers global key monitoring.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event.keyCode) == true ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            Task { @MainActor in
                _ = ScrollCaptureController.shared.handleKey(keyCode)
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            Task { @MainActor in
                ScrollCaptureController.shared.finish()
            }
        }
    }

    private func teardownCapture() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        hud?.orderOut(nil)
        hud = nil
        if let savedPointer {
            CGWarpMouseCursorPosition(savedPointer)
            CGAssociateMouseAndMouseCursorPosition(1)
            self.savedPointer = nil
        }
    }
}

/// Key-capable so the local key monitor keeps receiving Esc/Return while the
/// capture runs (there is no other key window at that point).
private final class ScrollCaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class ScrollCaptureHUDModel {
    var capturedPx = 0
}

/// "Capturing… 4,320 px · Click or ⏎ to finish · Esc to cancel"
struct ScrollCaptureHUDView: View {
    let model: ScrollCaptureHUDModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Capturing…  \(model.capturedPx.formatted()) px")
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            Text("Click or ⏎ to finish  ·  Esc to cancel")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
