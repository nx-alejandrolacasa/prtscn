import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "PreviewController")

/// A borderless panel that can become key (so hover + keyboard shortcuts work).
///
/// Plain `NSWindow`/`NSPanel` borderless windows refuse key status by default;
/// overriding `canBecomeKey` is what lets the preview receive mouse-moved and
/// key events without the user having to click it first — the exact problem the
/// Glaze version had to fight around.
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the (single, reused) preview panel: builds it, anchors it near the
/// cursor, and tears it down.
@MainActor
final class PreviewController {
    static let shared = PreviewController()

    private var panel: NSPanel?

    private init() {}

    func show(imageURL: URL, captureScale: CGFloat, pristineImage: NSImage? = nil) {
        guard let image = NSImage(contentsOf: imageURL) else { return }
        close()   // dismiss any existing preview first

        let model = PreviewModel(image: image, imageURL: imageURL,
                                 timeout: SettingsStore.shared.previewTimeout,
                                 captureScale: captureScale,
                                 pristineImage: pristineImage)
        model.onClose = { [weak self] in self?.close() }

        // Size the panel to the SwiftUI content. We use an NSHostingController
        // (rather than a bare NSHostingView) because its `view.fittingSize` is
        // computed reliably up front — a plain hosting view often reports zero
        // before it's inside a window, which would make the panel invisible.
        let hostingController = NSHostingController(rootView: PreviewCard(model: model))
        let measured = hostingController.view.fittingSize
        let size = (measured.width > 1 && measured.height > 1)
            ? measured
            : NSSize(width: 284, height: 240)   // fallback if SwiftUI hasn't sized yet

        let panel = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // the card draws its own shadow
        panel.level = .floating                 // above normal windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false         // don't vanish when focus leaves
        panel.acceptsMouseMovedEvents = true
        panel.contentViewController = hostingController

        position(panel, size: size)
        self.panel = panel

        // Activate so the panel becomes key — required on macOS for hover states
        // and keyboard shortcuts to fire without a preceding click. Focus
        // returns to the previous app once the panel closes.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        log.debug("preview shown — size=\(String(describing: size), privacy: .public), origin=\(String(describing: panel.frame.origin), privacy: .public)")
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Anchors the card by its bottom-left corner to the cursor: the visible
    /// card grows up and to the right from the pointer, so its lower-left corner
    /// is the point nearest the mouse. Flips horizontally and/or vertically only
    /// when that orientation would overflow the screen. Clamped to the visible
    /// area of whichever display the cursor is on.
    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation   // screen coords, origin bottom-left
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero

        // The panel includes a transparent shadow margin around the visible
        // card, so offset by it to position the *visible* edge near the cursor.
        let margin = PreviewCard.shadowMargin
        let gap: CGFloat = 6   // visible space between the card edge and cursor

        // Default: card's visible left edge just right of the cursor, growing
        // rightward (panel x = mouse.x + gap - margin).
        var x = mouse.x + gap - margin
        // Flip to the left if the card would overflow the right edge.
        if x + size.width > visible.maxX {
            x = mouse.x - gap + margin - size.width
        }

        // Default: card's visible bottom edge just above the cursor, growing
        // upward (panel y = mouse.y + gap - margin).
        var y = mouse.y + gap - margin
        // Flip below if the top would overflow the screen.
        if y + size.height > visible.maxY {
            y = mouse.y - gap + margin - size.height
        }

        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
