import AppKit

/// A borderless overlay panel that can become key, so Esc works without a
/// preceding click (same trick as `PreviewPanel`).
private final class FixedSizeOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Full-screen overlays (one per display) for the fixed-size capture: the
/// screen dims except for a rectangle of the chosen size that follows the
/// cursor. Click shoots that exact region; Esc (or switching away) cancels.
@MainActor
final class FixedSizeOverlay {
    static let shared = FixedSizeOverlay()

    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?

    var isActive: Bool { !panels.isEmpty }

    private init() {}

    func begin(size: CGSize, unit: FixedSizeUnit) {
        cancel()

        for screen in NSScreen.screens {
            let panel = FixedSizeOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver          // above everything, menu bar included
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = FixedSizeOverlayView(targetSize: size, unit: unit) { [weak self] rect in
                self?.finish(with: rect)
            }
            panels.append(panel)
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for panel in panels {
            if NSMouseInRect(mouse, panel.frame, false) {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFront(nil)
            }
        }

        // Esc cancels no matter which overlay window is key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // kVK_Escape
            self?.cancel()
            return nil
        }
        // ⌘-tabbing away would leave the overlay stranded on screen — cancel.
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in FixedSizeOverlay.shared.cancel() }
        }
    }

    func cancel() {
        teardown()
    }

    /// Click: dismiss the overlay first and give the window server a beat to
    /// actually remove it, so the dimming never shows up in the shot.
    private func finish(with rect: CGRect) {
        teardown()
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            ScreenshotService.shared.captureRect(rect)
        }
    }

    private func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let deactivateObserver {
            NotificationCenter.default.removeObserver(deactivateObserver)
            self.deactivateObserver = nil
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

/// One screen's overlay: dims the display, punches out the target rectangle
/// around the cursor, and reports the click in Cocoa screen coordinates.
private final class FixedSizeOverlayView: NSView {
    private let targetSize: CGSize
    private let unit: FixedSizeUnit
    private let onSelect: (CGRect) -> Void

    /// Cursor position in view coordinates; `nil` while it's on another screen.
    private var mouse: CGPoint?

    init(targetSize: CGSize, unit: FixedSizeUnit, onSelect: @escaping (CGRect) -> Void) {
        self.targetSize = targetSize
        self.unit = unit
        self.onSelect = onSelect
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Seed the rectangle right away if the cursor is already on this screen.
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        mouse = bounds.contains(point) ? point : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        guard let rect = captureRect, let window else { return }
        onSelect(window.convertToScreen(convert(rect, to: nil)))
    }

    /// This screen's backing scale — pixels per point, needed both to convert
    /// a pixel-unit target size and to align the rect with the pixel grid.
    private var screenScale: CGFloat {
        window?.screen?.backingScaleFactor ?? window?.backingScaleFactor ?? 2
    }

    /// `targetSize` in screen points. Pixel sizes divide by this screen's
    /// scale, so on Retina a 1280 px frame is 640 pt on screen (and half-point
    /// values are fine — screencapture accepts fractional rects).
    private var pointSize: CGSize {
        switch unit {
        case .points: targetSize
        case .pixels: CGSize(width: targetSize.width / screenScale,
                             height: targetSize.height / screenScale)
        }
    }

    /// The capture rectangle in view coordinates: `pointSize` centered on the
    /// cursor, clamped inside this screen (and shrunk to fit if it's larger
    /// than the screen), with the origin snapped to the pixel grid so the
    /// output is exactly the requested number of pixels.
    private var captureRect: CGRect? {
        guard let mouse else { return nil }
        let scale = screenScale
        let width = min(pointSize.width, bounds.width)
        let height = min(pointSize.height, bounds.height)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(
            x: snap(min(max(mouse.x - width / 2, 0), bounds.width - width)),
            y: snap(min(max(mouse.y - height / 2, 0), bounds.height - height)),
            width: width, height: height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()

        guard let rect = captureRect else { return }

        // "Punch out" the capture area. Not fully transparent: the window
        // server lets clicks fall through zero-alpha regions of a borderless
        // window, which would break click-to-capture exactly where it matters.
        // 2/255 of black is invisible but keeps the pixels hit-testable.
        NSColor.black.withAlphaComponent(0.008).setFill()
        rect.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        border.stroke()

        drawLabel(near: rect)
    }

    /// "1280 × 720 px · Click to capture, Esc to cancel" in a dark pill under
    /// the rectangle (or inside it when there's no room below).
    private func drawLabel(near rect: CGRect) {
        let text = "\(Int(targetSize.width)) × \(Int(targetSize.height)) \(unit.label)" +
            "   ·   Click to capture, Esc to cancel"
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let textSize = string.size()
        let pillSize = CGSize(width: textSize.width + 20, height: textSize.height + 10)

        var origin = CGPoint(x: rect.midX - pillSize.width / 2, y: rect.minY - pillSize.height - 8)
        if origin.y < 8 { origin.y = rect.minY + 8 }
        origin.x = min(max(origin.x, 8), bounds.width - pillSize.width - 8)

        let pill = CGRect(origin: origin, size: pillSize)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 5))
    }
}
