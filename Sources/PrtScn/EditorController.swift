import AppKit
import SwiftUI

/// Owns the (single, reused) editor window: builds it, sizes it to the capture,
/// centers it, and tears it down — the larger, titled sibling of
/// `PreviewController`.
@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    static let shared = EditorController()

    private var window: NSWindow?
    private var model: EditorModel?
    /// The size readout's two lines, kept to live-update while a crop is
    /// selected and after one is applied.
    private weak var sizeLabel: NSTextField?
    private weak var sizeCaption: NSTextField?
    /// Retained because `NSToolbar.delegate` is weak.
    private var toolbarDelegate: EditorToolbarDelegate?
    /// Local right-mouse event monitor that pans the zoomed capture.
    private var panMonitor: Any?
    private var isPanning = false
    /// One-shot observer that re-claims activation when the closing menu-bar
    /// menu hands focus back to the previous app (see `show`).
    private var reactivationObserver: NSObjectProtocol?

    private override init() {}

    /// Whether an editor window is open — what `DockIconMode.whileEditing`
    /// keys the Dock icon on.
    var isOpen: Bool { window != nil }

    /// Opens the editor for a capture. Takes ownership of `imageURL` (the temp
    /// file): the editor reuses it as its working file and deletes it on close.
    func show(imageURL: URL, captureScale: CGFloat) {
        guard let image = NSImage(contentsOf: imageURL) else { return }
        close()   // dismiss any existing editor first

        let model = EditorModel(image: image, workingURL: imageURL, captureScale: captureScale)
        model.onClose = { [weak self] in self?.close() }

        let hosting = NSHostingController(rootView: EditorView(model: model))
        // Don't let the hosting controller resize the window to the SwiftUI
        // content's fitting size — we set the window to the capture's 1:1 size
        // and the content must fill it (otherwise the image scales down to fit).
        hosting.sizingOptions = []
        let size = Self.windowSize(for: model)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrtScn"   // kept for Mission Control / the Window menu
        // No title text in the title bar itself — the brand lives in the menu
        // bar, and hiding it lets the tool groups hug the traffic lights.
        window.titleVisibility = .hidden
        window.contentViewController = hosting
        // Assigning the content view controller makes AppKit resize the window to
        // the SwiftUI view's fitting size (the minimum width), so force the
        // capture's 1:1 size back afterwards.
        window.setContentSize(size)
        window.contentMinSize = Self.minContentSize   // never shrink past the buttons
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        // A real NSToolbar so the system draws the action buttons in its current
        // design language — Liquid Glass capsules on macOS 26 — rather than the
        // flat custom controls a titlebar-accessory of SwiftUI buttons would give.
        let toolbarDelegate = EditorToolbarDelegate(model: model)
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Attaching the toolbar changes the title-bar height, and AppKit's
        // frame math then inflates a content size set before it (the window
        // opened ~32pt too tall, letterboxing the capture). Re-assert the
        // content size now that the final title-bar height is known.
        window.setContentSize(size)
        window.center()

        // Resize the window to fit the image after a crop.
        model.onGeometryChange = { [weak window, weak model] in
            guard let window, let model else { return }
            window.setContentSize(Self.windowSize(for: model))
            window.center()
        }

        self.window = window
        self.model = model
        self.toolbarDelegate = toolbarDelegate

        // Right-click drag and scrolling pan the capture while zoomed in, and
        // ⌘-scroll zooms. A local monitor (scoped to this window's content
        // area) sees the events no matter which SwiftUI view sits under the
        // cursor; left-clicks are untouched, so drawing/selecting keeps
        // working while zoomed. Monitors deliver on the main thread (hence
        // `assumeIsolated`), but NSEvent isn't Sendable, so its payload is
        // unpacked before crossing in.
        panMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel]
        ) { event in
            let windowID = event.window.map(ObjectIdentifier.init)
            let location = event.locationInWindow
            let consumed: Bool
            if event.type == .scrollWheel {
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                let precise = event.hasPreciseScrollingDeltas
                let zooming = event.modifierFlags.contains(.command)
                consumed = MainActor.assumeIsolated {
                    Self.shared.handleScroll(windowID: windowID, location: location,
                                             dx: dx, dy: dy, precise: precise,
                                             zooming: zooming)
                }
            } else {
                let type = event.type
                let dx = event.deltaX, dy = event.deltaY
                consumed = MainActor.assumeIsolated {
                    Self.shared.handlePan(type: type, windowID: windowID,
                                          location: location, dx: dx, dy: dy)
                }
            }
            return consumed ? nil : event
        }

        // Give the app a Dock icon / ⌘Tab slot while editing, if the Dock-icon
        // setting says so — the policy must be regular *before* activating.
        SettingsStore.shared.applyDockIcon()

        // Accessory (menu-bar) apps need an explicit activate for a normal
        // window to come forward and accept keyboard focus. When the editor
        // opens straight from the menu-bar dropdown (New Blank Canvas), the
        // closing menu hands focus back to the previous app *after* this runs,
        // burying the window — so order it front regardless of activation, and
        // re-assert the activation below once the menu's hand-back is done.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // The hand-back has no fixed timing — it can land later than any
        // runloop-turn deferral — and modern activation is cooperative, so a
        // re-`activate()` from the freshly deactivated app can be denied
        // outright. Don't bet the window on winning that fight: float it above
        // everything while the hand-back plays out (a floating window can't be
        // buried even if the other app stays active), and re-claim activation
        // on *every* deactivation in that span — the hand-back can land after
        // a first re-claim. Everything disarms after 1.5s, so the user
        // deliberately switching away isn't fought for long.
        window.level = .floating
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = Self.shared.window else { return }
                DispatchQueue.main.async {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        reactivationObserver = observer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak window] in
            if let self, self.reactivationObserver === observer {
                self.clearReactivationObserver()
            }
            if let window, window.level == .floating { window.level = .normal }
        }

        // Deferred a runloop turn: the readout anchors to the zoom control's
        // view, which AppKit only installs in the window hierarchy once the
        // title bar has been laid out — synchronously it isn't there yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let model = self.model else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            self.installSizeReadout(in: window, model: model)
        }
    }

    /// Consumes right-mouse events over the editor's content while zoomed in,
    /// turning the drag into a pan (with a grabbing-hand cursor). Returns
    /// whether the event was consumed.
    private func handlePan(type: NSEvent.EventType, windowID: ObjectIdentifier?,
                           location: NSPoint, dx: CGFloat, dy: CGFloat) -> Bool {
        guard let window, let model, windowID == ObjectIdentifier(window),
              model.canPan else { return false }
        switch type {
        case .rightMouseDown:
            guard let content = window.contentView,
                  content.bounds.contains(content.convert(location, from: nil))
            else { return false }
            isPanning = true
            NSCursor.closedHand.set()
        case .rightMouseDragged:
            guard isPanning else { return false }
            model.panBy(dx: dx, dy: dy)
        default:
            guard isPanning else { return false }
            isPanning = false
            NSCursor.arrow.set()
        }
        return true
    }

    /// Scrolling moves the capture (image tracks the gesture, like the
    /// right-click drag — `scrollingDelta` already honors the user's natural-
    /// scrolling preference, and momentum events keep flowing through for
    /// free inertia); ⌘-scrolling zooms about the canvas center, the same
    /// clamped path the pinch uses. Returns whether the event was consumed.
    private func handleScroll(windowID: ObjectIdentifier?, location: NSPoint,
                              dx: CGFloat, dy: CGFloat, precise: Bool,
                              zooming: Bool) -> Bool {
        guard let window, let model, windowID == ObjectIdentifier(window),
              let content = window.contentView,
              content.bounds.contains(content.convert(location, from: nil))
        else { return false }
        if zooming {
            // Trackpads report pixel deltas; a wheel notch reports whole
            // "lines" and needs amplifying to feel comparable.
            let step = precise ? dy : dy * 12
            model.setZoom(model.zoom * pow(1.004, step))
            return true
        }
        guard model.canPan else { return false }   // fitted or smaller — nothing to pan
        model.panBy(dx: dx, dy: dy)
        return true
    }

    /// The image-size readout: the capture's pixel dimensions over a small
    /// "Image size" caption, sitting right after the zoom group. Plain text
    /// added straight to the title-bar view and anchored to the zoom control —
    /// as a toolbar item macOS 26 would wrap it in its own glass capsule,
    /// exactly the chrome plain text shouldn't have. Clicking it copies the
    /// dimensions as text.
    private func installSizeReadout(in window: NSWindow, model: EditorModel) {
        // Hosted on the title-bar view (the traffic-light buttons' superview):
        // inside the title bar's visual-effect hierarchy, so the text gets the
        // same vibrant rendering as the toolbar's own labels — on the plain
        // window frame view it draws flat and reads heavier. Skip (no readout)
        // if either lookup isn't in this window's hierarchy.
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview,
              let zoomView = toolbarDelegate?.zoomView, zoomView.window === window
        else { return }

        let readout = model.sizeReadout
        let value = NSTextField(labelWithString: readout.value)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let caption = NSTextField(labelWithString: readout.caption)
        caption.font = .systemFont(ofSize: 9)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [value, caption])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.toolTip = "Image size in pixels — click to copy"
        stack.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(copySizeAction)))

        // Toolbar item views live in their own layout-engine domain (macOS 26)
        // — constraining an outside view to the zoom control throws — so the
        // readout is placed by frame: just after the zoom group, vertically
        // centered on it. The leading toolbar items are pinned to the left
        // edge, so the spot is stable; the autoresizing margins keep it
        // anchored to the window's top-left through resizes.
        let zoomFrame = zoomView.convert(zoomView.bounds, to: titlebar)
        let size = stack.fittingSize
        stack.setFrameSize(size)
        stack.setFrameOrigin(NSPoint(x: zoomFrame.maxX + 14,
                                     y: zoomFrame.midY - size.height / 2))
        stack.autoresizingMask = titlebar.isFlipped
            ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
        titlebar.addSubview(stack)
        sizeLabel = value
        sizeCaption = caption
        observeSize()
    }

    private func updateSizeReadout() {
        guard let model, let sizeLabel, let sizeCaption else { return }
        let readout = model.sizeReadout
        sizeLabel.stringValue = readout.value
        sizeCaption.stringValue = readout.caption
        // The digit count changes as a crop is dragged or applied; re-fit
        // (the origin stays put).
        if let stack = sizeLabel.superview as? NSStackView {
            stack.setFrameSize(stack.fittingSize)
        }
    }

    /// Re-renders the readout when what it shows changes (a crop selection
    /// being dragged, or the pixel dimensions after one is applied) — the
    /// same Observation pattern the toolbar's zoom percentage uses.
    private func observeSize() {
        withObservationTracking {
            _ = model?.sizeReadout
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.sizeLabel != nil else { return }
                self.updateSizeReadout()
                self.observeSize()
            }
        }
    }

    @objc private func copySizeAction() { model?.copySize() }

    func close() {
        model?.close()      // cleans up the temp file (guarded against re-entry)
        window?.orderOut(nil)
        teardown()
    }

    /// The standard close button routes here — tear down through the model so
    /// the temp file is cleaned up exactly once.
    func windowWillClose(_ notification: Notification) {
        model?.close()
        teardown()
    }

    private func clearReactivationObserver() {
        if let reactivationObserver {
            NotificationCenter.default.removeObserver(reactivationObserver)
        }
        reactivationObserver = nil
    }

    private func teardown() {
        clearReactivationObserver()
        window = nil
        model = nil
        toolbarDelegate = nil
        isPanning = false
        if let panMonitor { NSEvent.removeMonitor(panMonitor) }
        panMonitor = nil
        // The editor's color control targets the shared color panel at a proxy
        // owned by the (now torn down) view tree — de-target and dismiss it so
        // a later color change can't message a deallocated object.
        if NSColorPanel.sharedColorPanelExists {
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.setAction(nil)
            if panel.isVisible { panel.orderOut(nil) }
        }
        // Drop the "while editing" Dock icon now that no editor is open.
        SettingsStore.shared.applyDockIcon()
    }

    /// Breathing room between the floating palette / crop bar and the window's
    /// bottom edge. The capture itself runs edge-to-edge — the palette floats
    /// on top of it.
    static let paletteMargin: CGFloat = 16

    /// The smallest content area: wide enough that every title-bar toolbar
    /// item (crop/pixelate/eyedropper, the −/%/+ zoom group, and the export
    /// buttons) plus the image-size readout after zoom stays visible without
    /// the toolbar collapsing into the overflow chevron —
    /// and for the full tool palette; tall enough for a canvas that can still
    /// fit the measure loupe. The window otherwise hugs the capture's 1:1
    /// size, capped to the screen; captures smaller than this open centered
    /// over the checkerboard. (The title text is hidden, so the width only
    /// has to cover the tool groups.)
    static let minContentSize = NSSize(width: 760, height: 280)

    /// Sizes the window so the capture opens at full resolution: its true pixel
    /// dimensions mapped 1:1 to the screen's device pixels (pixels ÷ backing
    /// scale → points), edge-to-edge. The image — not its frame — is scaled
    /// down when a capture is too large for the screen (e.g. a full-screen
    /// grab), and the window never opens smaller than the toolbar needs.
    private static func windowSize(for model: EditorModel) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        // The capture's logical (1:1) size = pixels ÷ the scale it was taken at.
        var w = model.pixelSize.width / model.captureScale
        var h = model.pixelSize.height / model.captureScale
        guard w > 0, h > 0 else { return NSSize(width: 820, height: 620) }

        // Shrink the image to fit the visible screen (frame included) only if
        // needed; never enlarge.
        let fit = min(1, min(visible.width * 0.95 / w, visible.height * 0.95 / h))
        w *= fit
        h *= fit
        // Floor at the toolbar's minimum so the controls always fit.
        return NSSize(width: max(w.rounded(), minContentSize.width),
                      height: max(h.rounded(), minContentSize.height))
    }

}

/// Supplies the editor window's toolbar items (Copy / Save / Copy Text) as
/// native, bordered `NSToolbarItem`s — so the OS renders them in its current
/// design language. A `.flexibleSpace` pushes them to the trailing edge.
@MainActor
final class EditorToolbarDelegate: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    private let model: EditorModel
    /// The ( − | % | + ) control, kept to live-update its percentage segment.
    private weak var zoomControl: NSSegmentedControl?
    /// The zoom control's view, exposed so the controller can anchor the
    /// image-size readout right after it in the title bar.
    var zoomView: NSView? { zoomControl }

    private static let crop = NSToolbarItem.Identifier("PrtScn.crop")
    private static let pixelate = NSToolbarItem.Identifier("PrtScn.pixelate")
    private static let eyedropper = NSToolbarItem.Identifier("PrtScn.eyedropper")
    private static let zoom = NSToolbarItem.Identifier("PrtScn.zoom")
    private static let copy = NSToolbarItem.Identifier("PrtScn.copy")
    private static let save = NSToolbarItem.Identifier("PrtScn.save")
    private static let copyText = NSToolbarItem.Identifier("PrtScn.copyText")
    private static let share = NSToolbarItem.Identifier("PrtScn.share")

    init(model: EditorModel) {
        self.model = model
    }

    private var ordered: [NSToolbarItem.Identifier] {
        // Crop + Pixelate + Eyedropper (all act on the image itself) sit on the
        // leading side, with the zoom −/+ group set apart next to them; a space
        // sets Share apart from the Copy/Save/Copy Text export group on the
        // trailing side.
        [Self.crop, Self.pixelate, Self.eyedropper, .space, Self.zoom, .flexibleSpace,
         Self.copy, Self.save, Self.copyText, .space, Self.share]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ordered }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ordered }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.zoom {
            // One connected ( − | 100% | + ) control: a segmented control with
            // the live zoom percentage as a display-only middle segment.
            let control = NSSegmentedControl()
            control.segmentCount = 3
            control.trackingMode = .momentary
            control.setImage(NSImage(systemSymbolName: "minus.magnifyingglass",
                                     accessibilityDescription: "Zoom Out"), forSegment: 0)
            control.setLabel("100%", forSegment: 1)
            control.setEnabled(false, forSegment: 1)   // a readout, not a button
            // Fixed width: no jitter as digits change, and roomy enough that
            // even "1000%" never truncates to an ellipsis.
            control.setWidth(58, forSegment: 1)
            control.setImage(NSImage(systemSymbolName: "plus.magnifyingglass",
                                     accessibilityDescription: "Zoom In"), forSegment: 2)
            control.target = self
            control.action = #selector(zoomAction(_:))

            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.view = control
            group.label = "Zoom"
            group.toolTip = "Zoom (⌘− / ⌘+, ⌘0 resets, or pinch)"
            zoomControl = control
            updateZoomLabel()
            observeZoomPercent()
            return group
        }

        if id == Self.share {
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.toolTip = "Share"
            // Autovalidation calls our `items(for:)` every ~150ms; skip it so
            // building the share payload isn't a constant (side-effecting) cost.
            item.autovalidates = false
            item.delegate = self
            return item
        }

        let spec: (symbol: String, label: String, tip: String, action: Selector)
        switch id {
        case Self.crop:
            spec = ("crop", "Crop", "Crop", #selector(cropAction))
        case Self.pixelate:
            spec = ("eye.slash", "Pixelate", "Pixelate (P)", #selector(pixelateAction))
        case Self.eyedropper:
            spec = ("eyedropper", "Pick Color", "Pick Color", #selector(eyedropperAction))
        case Self.copy:
            spec = ("doc.on.doc", "Copy", "Copy (⌘C)", #selector(copyAction))
        case Self.save:
            spec = ("square.and.arrow.down", "Save", "Save (⌘S)", #selector(saveAction))
        case Self.copyText:
            spec = ("text.viewfinder", "OCR", "Copy text with OCR (⌘T)", #selector(copyTextAction))
        default:
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.label = spec.label
        item.toolTip = spec.tip
        item.isBordered = true          // render as a native (glass) button
        item.target = self
        item.action = spec.action
        return item
    }

    @objc private func zoomAction(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { model.zoomOut() } else { model.zoomIn() }
    }

    private func updateZoomLabel() {
        zoomControl?.setLabel("\(model.zoomPercent)%", forSegment: 1)
    }

    /// Re-renders the percentage segment whenever anything `zoomPercent` reads
    /// (zoom, canvas size, crop) changes — the Observation equivalent of what
    /// a SwiftUI view would do automatically, re-armed after each change.
    private func observeZoomPercent() {
        withObservationTracking {
            _ = model.zoomPercent
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.zoomControl != nil else { return }
                self.updateZoomLabel()
                self.observeZoomPercent()
            }
        }
    }

    @objc private func cropAction() { model.beginCrop() }
    @objc private func pixelateAction() { model.tool = .pixelate }
    @objc private func eyedropperAction() { model.beginPickingColor() }
    @objc private func copyAction() { model.copy() }
    @objc private func saveAction() { model.save() }
    @objc private func copyTextAction() { model.copyText() }

    // MARK: - Share

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        [model.sharingItem()]
    }
}
