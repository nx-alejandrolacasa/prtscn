import AppKit
import SwiftUI

/// A pinned screenshot's window: borderless, floating, and non-activating so
/// pinning never steals focus from the app being worked in. Scroll or pinch
/// resizes the pin around its center.
final class PinnedPanel: NSPanel {
    /// The pin's initial fitted size (scale 1) — what a double-click resets to.
    var baseContentSize = NSSize(width: 1, height: 1)
    private var imageScale: CGFloat = 1

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.05
        apply(scale: imageScale * (1 + event.scrollingDeltaY * step))
    }

    override func magnify(with event: NSEvent) {
        apply(scale: imageScale * (1 + event.magnification))
    }

    /// Rescales the pin around its center, clamped between a legible minimum
    /// (~80pt long edge) and its screen's visible area.
    func apply(scale: CGFloat) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: baseContentSize)
        let fitScreen = min(visible.width / baseContentSize.width,
                            visible.height / baseContentSize.height)
        let minScale = min(1, 80 / max(baseContentSize.width, baseContentSize.height))
        let clamped = min(max(scale, minScale), max(minScale, min(3, fitScreen)))
        guard clamped != imageScale else { return }
        imageScale = clamped

        let size = NSSize(width: (baseContentSize.width * clamped).rounded(),
                          height: (baseContentSize.height * clamped).rounded())
        setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(),
                        y: (frame.midY - size.height / 2).rounded(),
                        width: size.width, height: size.height),
                 display: true)
        invalidateShadow()   // the system shadow tracks the rounded clip shape
    }
}

/// Hosting view that responds to the first click even while the panel isn't
/// key. The pin panel is non-activating and never becomes key on its own, and
/// a plain NSHostingView swallows the first click on a non-key window — so the
/// close button would need one click to "arm" the pin and a second to fire.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Transparent click target used for the pin close affordance. SwiftUI buttons
/// can still lose the first click in a non-activating panel, so the close hit
/// area uses AppKit's first-mouse path directly.
final class FirstMouseClickTargetView: NSView {
    var onClick: (() -> Void)?

    private var armed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        armed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { armed = false }
        guard armed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

private struct FirstMouseClickTarget: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> FirstMouseClickTargetView {
        let view = FirstMouseClickTargetView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: FirstMouseClickTargetView, context: Context) {
        nsView.onClick = onClick
    }
}

/// Owns every pinned-screenshot window. `@Observable` so the menu-bar dropdown
/// can offer "Close All Pins" only while pins exist.
@MainActor
@Observable
final class PinnedController {
    static let shared = PinnedController()

    private struct Pin {
        let panel: PinnedPanel
        let url: URL
    }

    private var pins: [Pin] = []

    /// Mirror of `pins.count` for observation (drives the menu item).
    private(set) var count = 0

    var hasPins: Bool { count > 0 }

    private init() {}

    /// Pins `image` as an always-on-top floating window centered on the cursor.
    /// The pin takes ownership of the temp file at `imageURL` — its context
    /// menu still needs it for Copy/Save/Edit — and deletes it on close.
    func pin(image rawImage: NSImage, imageURL: URL, captureScale: CGFloat) {
        let image = Self.trimmedToOpaqueBounds(rawImage)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Start at the capture's natural (point) size, scaled down to at most
        // half the screen so a big grab doesn't wall off the workspace.
        let natural = image.size
        let fit = min(1, visible.width * 0.5 / max(natural.width, 1),
                      visible.height * 0.5 / max(natural.height, 1))
        let size = NSSize(width: (natural.width * fit).rounded(),
                          height: (natural.height * fit).rounded())

        let panel = PinnedPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.baseContentSize = size
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                  // system shadow, follows the rounded shape
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true        // hover chrome without key status
        panel.isMovableByWindowBackground = false   // WindowDragGesture moves it instead

        let card = PinnedCard(
            image: image,
            onCopy: { ScreenshotService.shared.copyToClipboard(imageURL) },
            onSave: { ScreenshotService.shared.save(imageURL) },
            onEdit: { [weak self, weak panel] in
                EditorController.shared.show(imageURL: imageURL, captureScale: captureScale)
                // The editor owns the temp file now — close without deleting it.
                if let panel { self?.close(panel, cleanup: false) }
            },
            onClose: { [weak self, weak panel] in
                if let panel { self?.close(panel, cleanup: true) }
            },
            onResetSize: { [weak panel] in panel?.apply(scale: 1) }
        )
        panel.contentView = FirstMouseHostingView(rootView: card)

        // Center on the cursor, clamped on-screen. Asserted *after* the
        // content view is attached so nothing re-derives the frame from the
        // view's fitting size.
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        panel.orderFront(nil)   // no makeKey — pinning shouldn't steal focus
        pins.append(Pin(panel: panel, url: imageURL))
        count = pins.count
    }

    func closeAll() {
        for pin in pins.reversed() { close(pin.panel, cleanup: true) }
    }

    private func close(_ panel: PinnedPanel, cleanup: Bool) {
        guard let index = pins.firstIndex(where: { $0.panel === panel }) else { return }
        let pin = pins.remove(at: index)
        count = pins.count
        pin.panel.orderOut(nil)
        if cleanup { ScreenshotService.shared.cleanup(pin.url) }
    }

    /// A window shot's PNG is the window plus a transparent surround holding
    /// macOS's baked drop shadow — pinned as-is it reads as a huge fuzzy halo.
    /// Trim to the (nearly) opaque pixels so every pin is a tight rectangle
    /// that gets the same frame chrome. Opaque captures come back unchanged.
    private static func trimmedToOpaqueBounds(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return image }

        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The window body is fully opaque; the baked shadow tops out well
        // below this, so a high threshold separates them cleanly.
        let threshold: UInt8 = 250
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] >= threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        // Fully transparent (shouldn't happen) or already opaque edge-to-edge:
        // nothing to trim.
        guard maxX >= minX, maxY >= minY,
              minX > 0 || minY > 0 || maxX < width - 1 || maxY < height - 1,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY,
                                                   width: maxX - minX + 1,
                                                   height: maxY - minY + 1))
        else { return image }

        // Preserve the point size ↔ pixel size relationship (Retina scale).
        let scale = CGFloat(width) / max(image.size.width, 1)
        return NSImage(cgImage: cropped,
                       size: NSSize(width: CGFloat(cropped.width) / scale,
                                    height: CGFloat(cropped.height) / scale))
    }
}

/// The pinned window's content: the screenshot with a hairline edge, a hover
/// close button, and a right-click menu carrying the capture actions.
private struct PinnedCard: View {
    let image: NSImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void
    let onResetSize: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        screenshot
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded(onResetSize))
            .contextMenu { menuItems }
            .overlay(alignment: .topLeading) { closeButton }
            .onHover { hovering = $0 }
            .background(shortcutHandlers)
            // Let the click that lands on a non-key pin also *act* — without
            // this, the first click on the close button is spent focusing the
            // panel and only a second click fires the button.
            .allowsWindowActivationEvents()
    }

    private var screenshot: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()   // window aspect always matches the image, so no crop
            .clipShape(shape)
            .overlay(shape.inset(by: 0.5).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .overlay(shape.strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }

    private var closeButton: some View {
        ZStack {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .glassEffect(.regular, in: Circle())
            FirstMouseClickTarget(onClick: onClose)
                .frame(width: 22, height: 22)
        }
        .padding(6)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Same bindings as the preview card: ⌘C copy, ⌘S save, ⏎ edit, Esc close.
    /// Shown on the context-menu items and mirrored by `shortcutHandlers`'s hidden
    /// buttons so they also fire while the menu is closed.
    @ViewBuilder
    private var menuItems: some View {
        Button("Copy Image", systemImage: "doc.on.doc", action: onCopy)
            .keyboardShortcut("c", modifiers: .command)
        Button("Save", systemImage: "square.and.arrow.down", action: onSave)
            .keyboardShortcut("s", modifiers: .command)
        Button("Edit…", systemImage: "pencil.and.outline", action: onEdit)
            .keyboardShortcut(.return, modifiers: [])
        Divider()
        Button("Close Pin", systemImage: "pin.slash", action: onClose)
            .keyboardShortcut(.cancelAction)
        Button("Close All Pins") { PinnedController.shared.closeAll() }
    }

    /// Invisible buttons carrying the pin's keyboard shortcuts — active while
    /// the pin is key (i.e. after a click on it), no context menu needed.
    private var shortcutHandlers: some View {
        Group {
            Button("", action: onCopy).keyboardShortcut("c", modifiers: .command)
            Button("", action: onSave).keyboardShortcut("s", modifiers: .command)
            Button("", action: onEdit).keyboardShortcut(.return, modifiers: [])
            Button("", action: onClose).keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}
