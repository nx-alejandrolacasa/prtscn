import AppKit

/// A borderless overlay panel that can become key, so Esc works without a
/// preceding click (same trick as `FixedSizeOverlayPanel`).
private final class ScrollSelectPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Full-screen overlays (one per display) for the scrolling capture: the
/// screen dims and the user drags out the region to auto-scroll. Releasing
/// the drag reports the rectangle; Esc (or switching away) cancels.
@MainActor
final class ScrollCaptureOverlay {
    static let shared = ScrollCaptureOverlay()

    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var onSelect: ((CGRect, NSScreen, Bool) -> Void)?
    private var onCancel: (() -> Void)?

    private init() {}

    /// `onSelect` receives the dragged rectangle in Cocoa screen coordinates,
    /// the screen it lives on, and whether ⌘ was held on release (capture
    /// upward — chats). The overlay is already torn down when either
    /// callback fires.
    func begin(onSelect: @escaping (CGRect, NSScreen, Bool) -> Void,
               onCancel: @escaping () -> Void) {
        cancel()
        self.onSelect = onSelect
        self.onCancel = onCancel

        for screen in NSScreen.screens {
            let panel = ScrollSelectPanel(
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
            panel.contentView = ScrollSelectView { [weak self] rect, screen, scrollUp in
                self?.finish(with: rect, on: screen, scrollUp: scrollUp)
            }
            panels.append(panel)
        }

        NSApp.activate()
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
            Task { @MainActor in ScrollCaptureOverlay.shared.cancel() }
        }
    }

    func cancel() {
        let callback = onCancel
        teardown()
        callback?()
    }

    /// Mouse-up: dismiss the overlay first; the controller waits a beat before
    /// the first frame so the dimming never shows up in the stitch.
    private func finish(with rect: CGRect, on screen: NSScreen, scrollUp: Bool) {
        let select = onSelect
        teardown()
        select?(rect, screen, scrollUp)
    }

    private func teardown() {
        onSelect = nil
        onCancel = nil
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

/// One screen's overlay: dims the display and lets the user drag out a
/// rubber-band rectangle, reported on mouse-up in Cocoa screen coordinates.
private final class ScrollSelectView: NSView {
    private let onSelect: (CGRect, NSScreen, Bool) -> Void

    /// Drag anchor and current point in view coordinates; nil before the drag.
    private var anchor: CGPoint?
    private var current: CGPoint?
    /// Live ⌘ state plus when it was last seen held, so the label can show
    /// the direction mid-drag and a release survives the grace window.
    private var commandHeld = false
    private var lastCommandAt: TimeInterval = -.infinity

    /// Selections smaller than this (either dimension, in points) are treated
    /// as a slip of the mouse — the overlay stays up for another try.
    private static let minSelection: CGFloat = 40
    /// Releasing ⌘ a beat before the mouse button shouldn't lose the upward
    /// intent — ⌘ counts as engaged for this long after it goes up.
    private static let commandGrace: TimeInterval = 0.5
    /// How long the "scrolling up" tag takes to fade/slide in or out.
    private static let indicatorFade: TimeInterval = 0.18

    /// 0 = tag hidden, 1 = fully shown; walked toward the engaged state by
    /// a short 60 Hz timer so the pill grows and fades instead of snapping.
    /// The timer also keeps ticking through the grace window, which is what
    /// triggers the fade-out the moment the grace expires.
    private var indicatorProgress: CGFloat = 0
    private var indicatorTimer: Timer?

    private func animateIndicatorIfNeeded() {
        guard indicatorTimer == nil else { return }
        guard indicatorProgress != (scrollUpEngaged ? 1 : 0) || commandHeld != scrollUpEngaged
        else { return }
        indicatorTimer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self,
                                              selector: #selector(indicatorTick),
                                              userInfo: nil, repeats: true)
    }

    @objc private func indicatorTick() {
        let target: CGFloat = scrollUpEngaged ? 1 : 0
        let step = CGFloat(1.0 / 60.0 / Self.indicatorFade)
        if indicatorProgress < target {
            indicatorProgress = min(target, indicatorProgress + step)
        } else if indicatorProgress > target {
            indicatorProgress = max(target, indicatorProgress - step)
        }
        needsDisplay = true
        // Done only when settled AND no grace window is pending expiry.
        if indicatorProgress == target, commandHeld == scrollUpEngaged {
            indicatorTimer?.invalidate()
            indicatorTimer = nil
        }
    }

    /// Whether the capture would scroll up if the drag ended now: ⌘ is down,
    /// or went up less than the grace window ago.
    private var scrollUpEngaged: Bool {
        commandHeld || ProcessInfo.processInfo.systemUptime - lastCommandAt < Self.commandGrace
    }

    /// `NSEvent.timestamp` shares the `systemUptime` clock, so the grace
    /// comparison in `scrollUpEngaged` is exact.
    private func noteModifiers(_ event: NSEvent) {
        commandHeld = event.modifierFlags.contains(.command)
        if commandHeld { lastCommandAt = event.timestamp }
        animateIndicatorIfNeeded()
    }

    /// The target-based timer retains the view — break the pair when the
    /// overlay panel tears down, or both would outlive it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            indicatorTimer?.invalidate()
            indicatorTimer = nil
        }
    }

    init(onSelect: @escaping (CGRect, NSScreen, Bool) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        noteModifiers(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        noteModifiers(event)
        needsDisplay = true
    }

    /// Pressing or releasing ⌘ without moving the mouse must still refresh
    /// the direction hint (the indicator timer inside `noteModifiers` then
    /// carries the animation through the grace window and out).
    override func flagsChanged(with event: NSEvent) {
        noteModifiers(event)
        needsDisplay = true
        super.flagsChanged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        noteModifiers(event)
        let scrollUp = scrollUpEngaged
        defer { anchor = nil; current = nil; needsDisplay = true }
        guard let rect = selectionRect, let window, let screen = window.screen,
              rect.width >= Self.minSelection, rect.height >= Self.minSelection
        else { return }
        onSelect(window.convertToScreen(convert(rect, to: nil)), screen, scrollUp)
    }

    /// This screen's backing scale — pixels per point, to align the selection
    /// with the pixel grid so the frames are pixel-exact.
    private var screenScale: CGFloat {
        window?.screen?.backingScaleFactor ?? window?.backingScaleFactor ?? 2
    }

    /// The rubber-band rectangle in view coordinates, clamped to this screen
    /// and snapped to the pixel grid.
    private var selectionRect: CGRect? {
        guard let anchor, let current else { return nil }
        let scale = screenScale
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let raw = CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                         width: abs(anchor.x - current.x), height: abs(anchor.y - current.y))
            .intersection(bounds)
        guard !raw.isEmpty else { return nil }
        return CGRect(x: snap(raw.minX), y: snap(raw.minY),
                      width: snap(raw.width), height: snap(raw.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()

        guard let rect = selectionRect else {
            drawLabel("Drag over scrollable content   ·   Hold ⌘ to scroll up   ·   Esc to cancel",
                      centeredAbove: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }

        // "Punch out" the selection. Not fully transparent: the window server
        // lets clicks fall through zero-alpha regions of a borderless window,
        // which would break the drag exactly where it matters. 2/255 of black
        // is invisible but keeps the pixels hit-testable.
        NSColor.black.withAlphaComponent(0.008).setFill()
        rect.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        border.stroke()

        drawLabel("\(Int(rect.width)) × \(Int(rect.height)) pt",
                  suffix: "   ·   ⌘ scrolling up ↑", progress: indicatorProgress,
                  centeredAbove: CGPoint(x: rect.midX, y: rect.minY - 8))
    }

    /// A dark pill with white text, centered horizontally on `point` and
    /// drawn just below it (or nudged back on-screen at the edges). An
    /// optional `suffix` slides and fades in as `progress` goes 0 → 1: the
    /// pill widens to make room while the text gains opacity, clipped to the
    /// pill so it's revealed rather than squeezed.
    private func drawLabel(_ text: String, suffix: String? = nil, progress: CGFloat = 0,
                           centeredAbove point: CGPoint) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white,
        ])
        let eased = progress * progress * (3 - 2 * progress)   // smoothstep
        let suffixString: NSAttributedString? = (suffix != nil && eased > 0)
            ? NSAttributedString(string: suffix ?? "", attributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(eased),
            ])
            : nil
        let textSize = string.size()
        let suffixWidth = (suffixString?.size().width ?? 0) * eased
        let pillSize = CGSize(width: textSize.width + suffixWidth + 20,
                              height: textSize.height + 10)

        var origin = CGPoint(x: point.x - pillSize.width / 2, y: point.y - pillSize.height)
        origin.y = min(max(origin.y, 8), bounds.height - pillSize.height - 8)
        origin.x = min(max(origin.x, 8), bounds.width - pillSize.width - 8)

        let pill = CGRect(origin: origin, size: pillSize)
        let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2,
                                 yRadius: pill.height / 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        shape.fill()
        string.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 5))
        if let suffixString {
            NSGraphicsContext.current?.saveGraphicsState()
            shape.addClip()
            suffixString.draw(at: CGPoint(x: pill.minX + 10 + textSize.width,
                                          y: pill.minY + 5))
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}
