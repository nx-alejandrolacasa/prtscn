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
    /// Retained because `NSToolbar.delegate` is weak.
    private var toolbarDelegate: EditorToolbarDelegate?

    private override init() {}

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
        let size = Self.windowSize(for: image, captureScale: captureScale)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrtScn"
        window.contentViewController = hosting
        // Assigning the content view controller makes AppKit resize the window to
        // the SwiftUI view's fitting size (the 600pt min width), so force the
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

        // Resize the window to fit the image after a crop.
        model.onGeometryChange = { [weak window, weak model] in
            guard let window, let model else { return }
            window.setContentSize(Self.windowSize(for: model.baseImage, captureScale: model.captureScale))
            window.center()
        }

        self.window = window
        self.model = model
        self.toolbarDelegate = toolbarDelegate

        // Accessory (menu-bar) apps need an explicit activate for a normal
        // window to come forward and accept keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        model?.close()      // cleans up the temp file (guarded against re-entry)
        window?.orderOut(nil)
        window = nil
        model = nil
        toolbarDelegate = nil
    }

    /// The standard close button routes here — tear down through the model so
    /// the temp file is cleaned up exactly once.
    func windowWillClose(_ notification: Notification) {
        model?.close()
        window = nil
        model = nil
        toolbarDelegate = nil
    }

    /// The smallest content area: wide enough for the full tool palette (and the
    /// title-bar buttons), with just enough height for the palette. The window
    /// otherwise hugs the capture's 1:1 size, capped to the screen — so it isn't
    /// letterboxed around a short image.
    static let minContentSize = NSSize(width: 600, height: 200)

    /// Sizes the window so the capture opens at full resolution: its true pixel
    /// dimensions mapped 1:1 to the screen's device pixels (pixels ÷ backing
    /// scale → points). The window hugs the screenshot — it isn't enlarged past
    /// it — except that it never opens smaller than the toolbar needs, and a
    /// capture too large to fit (e.g. a full-screen grab) is scaled down,
    /// preserving aspect.
    private static func windowSize(for image: NSImage, captureScale: CGFloat) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let pixels = pixelSize(of: image)
        // The capture's logical (1:1) size = pixels ÷ the scale it was taken at.
        var w = pixels.width / max(captureScale, 1)
        var h = pixels.height / max(captureScale, 1)
        guard w > 0, h > 0 else { return NSSize(width: 820, height: 620) }

        // Shrink to fit the visible screen only if needed; never enlarge.
        let fit = min(1, min(visible.width * 0.95 / w, visible.height * 0.95 / h))
        w *= fit
        h *= fit
        // Floor at the toolbar's minimum so the controls always fit.
        return NSSize(width: max(w.rounded(), minContentSize.width),
                      height: max(h.rounded(), minContentSize.height))
    }

    /// The capture's real pixel dimensions, read from its bitmap representation
    /// (independent of any DPI metadata in `NSImage.size`).
    private static func pixelSize(of image: NSImage) -> NSSize {
        var width = 0
        var height = 0
        for rep in image.representations {
            width = max(width, rep.pixelsWide)
            height = max(height, rep.pixelsHigh)
        }
        return width > 0 && height > 0
            ? NSSize(width: width, height: height)
            : image.size
    }
}

/// Supplies the editor window's toolbar items (Copy / Save / Copy Text) as
/// native, bordered `NSToolbarItem`s — so the OS renders them in its current
/// design language. A `.flexibleSpace` pushes them to the trailing edge.
@MainActor
final class EditorToolbarDelegate: NSObject, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    private let model: EditorModel

    private static let crop = NSToolbarItem.Identifier("PrtScn.crop")
    private static let pixelate = NSToolbarItem.Identifier("PrtScn.pixelate")
    private static let eyedropper = NSToolbarItem.Identifier("PrtScn.eyedropper")
    private static let copy = NSToolbarItem.Identifier("PrtScn.copy")
    private static let save = NSToolbarItem.Identifier("PrtScn.save")
    private static let copyText = NSToolbarItem.Identifier("PrtScn.copyText")
    private static let share = NSToolbarItem.Identifier("PrtScn.share")

    init(model: EditorModel) {
        self.model = model
    }

    private var ordered: [NSToolbarItem.Identifier] {
        // Crop + Pixelate + Eyedropper (all act on the image itself) sit on the
        // leading side; a space sets Share apart from the Copy/Save/Copy Text
        // export group on the trailing side.
        [Self.crop, Self.pixelate, Self.eyedropper, .flexibleSpace,
         Self.copy, Self.save, Self.copyText, .space, Self.share]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ordered }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ordered }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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
            spec = ("eye.slash", "Pixelate", "Pixelate", #selector(pixelateAction))
        case Self.eyedropper:
            spec = ("eyedropper", "Pick Color", "Pick Color", #selector(eyedropperAction))
        case Self.copy:
            spec = ("doc.on.doc", "Copy", "Copy (⌘C)", #selector(copyAction))
        case Self.save:
            spec = ("square.and.arrow.down", "Save", "Save (⌘S)", #selector(saveAction))
        case Self.copyText:
            spec = ("text.viewfinder", "Copy Text", "Copy Text (⌘T)", #selector(copyTextAction))
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
