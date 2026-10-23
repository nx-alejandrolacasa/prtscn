import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "EditorController")

/// Owns the (single, reused) editor window. Captures open it immersive —
/// a borderless window covering the screen, the blurred wallpaper behind, the
/// capture centered at 1:1, the tools floating along the top and bottom
/// edges — instantly, with no full-screen Space to animate in and out. Blank
/// canvases and projects open it as a normal window. The green button, ⌃⌘F
/// and the bar's exit button move between the two, and switching to another
/// app drops the immersive editor into a window so it never stands in the way.
@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    static let shared = EditorController()

    private var window: NSWindow?
    private var model: EditorModel?
    /// The frame to come back to when leaving immersive mode.
    private var windowedFrame = NSRect.zero
    /// Drops to a window when the user switches to another app while immersive.
    private var immersiveExitObserver: NSObjectProtocol?
    /// The blurred desktop picture, shown only while full screen.
    private weak var wallpaperView: NSView?
    /// The size readout's two lines, kept to live-update while a crop is
    /// selected and after one is applied.
    private weak var sizeLabel: NSTextField?
    private weak var sizeCaption: NSTextField?
    /// Retained because `NSToolbar.delegate` is weak.
    private var toolbarDelegate: EditorToolbarDelegate?
    /// Retained because going borderless detaches it from the window.
    private var toolbar: NSToolbar?
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
    /// A capture the open editor can't make way for is saved to the save
    /// folder rather than lost, unless `saveIfRefused` is off.
    func show(imageURL: URL, captureScale: CGFloat, saveIfRefused: Bool = true,
              fullScreen: Bool = true) {
        guard let image = NSImage(contentsOf: imageURL) else { return }
        if !present(EditorModel(image: image, workingURL: imageURL, captureScale: captureScale),
                    fullScreen: fullScreen) {
            if saveIfRefused { _ = ScreenshotService.shared.save(imageURL, captureScale: captureScale) }
            ScreenshotService.shared.cleanup(imageURL)
        }
    }

    /// Reopens a `.prtscn` project; the annotations come back as editable data.
    func open(projectURL: URL) {
        guard let (model, document) = loadProject(at: projectURL) else { return }
        guard present(model) else { return ScreenshotService.shared.cleanup(model.workingURL) }
        model.restore(document, from: projectURL)
    }

    /// Reopens the canvas a crash left behind, still writing its snapshots
    /// into the same package until it's saved or closed.
    /// An unreadable snapshot goes to the Trash so it isn't offered again.
    func recover(from snapshotURL: URL, originalDocumentURL: URL?) {
        guard let (model, document) = loadProject(at: snapshotURL,
                                                  recovery: CanvasRecovery(adopting: snapshotURL))
        else {
            try? FileManager.default.trashItem(at: snapshotURL, resultingItemURL: nil)
            return
        }
        guard present(model) else { return ScreenshotService.shared.cleanup(model.workingURL) }
        model.restoreRecovered(document, originalDocumentURL: originalDocumentURL)
    }

    /// A model over the package's base image, which becomes a fresh temp
    /// working file (the editor owns and deletes it, like a capture's).
    /// Alerts and returns `nil` when the package can't be read.
    private func loadProject(at url: URL, recovery: CanvasRecovery = CanvasRecovery())
        -> (EditorModel, ProjectDocument)? {
        let image: NSImage, document: ProjectDocument
        do {
            (image, document) = try ProjectDocument.read(from: url)
        } catch {
            log.error("couldn't open project at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't open “\(url.lastPathComponent)”")
            alert.informativeText = String(localized: "The file isn't a PrtScn project this version can read.")
            NSApp.activate()
            alert.runModal()
            return nil
        }
        let workingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prtscn-project-\(UUID().uuidString).png")
        let model = EditorModel(image: image, workingURL: workingURL,
                                captureScale: document.captureScale, recovery: recovery)
        return (model, document)
    }

    /// Lets the user pick a `.prtscn` project to reopen.
    func openProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.prtscnProject]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: SettingsStore.shared.saveFolderPath, isDirectory: true)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(projectURL: url)
    }

    /// Returns whether `model` made it on screen; when refused, its working
    /// file is the caller's to deal with.
    private func present(_ model: EditorModel, fullScreen: Bool = false) -> Bool {
        // The open editor is mid-conversation (a save panel or the unsaved-
        // changes sheet); it can't be torn down under it.
        if let window, window.attachedSheet != nil {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // A dirty project is already open: the user decides before it goes.
        if let current = self.model, current.hasUnsavedProjectChanges {
            switch askUnsavedChanges(for: current) {
            case .save: guard current.saveProject() else { fallthrough }
            case .cancel: return false
            case .discard: break
            }
        }
        close()   // dismiss any existing editor first
        // Guarded by identity: a model closes asynchronously, by which time a
        // newer editor may be the one on screen.
        model.onClose = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.close()
        }

        let size = Self.windowSize(for: model)
        let window = EditorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: Self.windowedStyle,
            backing: .buffered,
            defer: false
        )
        window.title = "PrtScn"   // kept for Mission Control / the Window menu
        // No title text in the title bar itself — the brand lives in the menu
        // bar, and hiding it lets the tool groups hug the traffic lights.
        window.titleVisibility = .hidden
        window.contentMinSize = Self.minContentSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.delegate = self

        // Immersive shows just the wallpaper, blurred — no other windows:
        // the desktop picture (captured, so dynamic wallpapers work) under an
        // in-window full-screen-UI material, with the SwiftUI editor laid over
        // both. Windowed, the picture is hidden and the material reads as a
        // plain window background.
        let bounds = window.contentView?.bounds ?? .zero
        let wallpaper = NSView(frame: bounds)
        wallpaper.wantsLayer = true
        wallpaper.layer?.contentsGravity = .resizeAspectFill
        wallpaper.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        wallpaper.autoresizingMask = [.width, .height]
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: EditorView(model: model))
        // Never let the hosting view size the window to the SwiftUI fitting
        // size — the content fills the screen.
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        wallpaper.isHidden = true
        window.contentView?.addSubview(wallpaper)
        window.contentView?.addSubview(blur)
        window.contentView?.addSubview(hosting)

        // Windowed, the tools live in a real NSToolbar so the system draws
        // them in its current design language; full screen hides it in
        // favor of the floating glass bar.
        let toolbarDelegate = EditorToolbarDelegate(model: model)
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        toolbar.isVisible = !fullScreen
        // Attaching the toolbar changes the title-bar height, and AppKit's
        // frame math then inflates a content size set before it. Re-assert
        // the content size now that the final title-bar height is known.
        window.setContentSize(size)
        window.center()

        self.window = window
        self.model = model
        self.wallpaperView = wallpaper
        self.toolbarDelegate = toolbarDelegate
        self.toolbar = toolbar
        model.hostWindow = window
        observeUnsavedChanges()

        // Right-click drag and scrolling pan the capture while zoomed in, and
        // ⌘-scroll zooms. A local monitor (scoped to this window's content
        // area) sees the events no matter which SwiftUI view sits under the
        // cursor; left-clicks are untouched, so drawing/selecting keeps
        // working while zoomed. Monitors deliver on the main thread (hence
        // `assumeIsolated`), but NSEvent isn't Sendable, so its payload is
        // unpacked before crossing in.
        panMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel, .keyDown]
        ) { event in
            let windowID = event.window.map(ObjectIdentifier.init)
            let location = event.locationInWindow
            let consumed: Bool
            if event.type == .keyDown {
                let key = event.specialKey?.rawValue
                let escape = event.keyCode == 53
                let shift = event.modifierFlags.contains(.shift)
                let command = event.modifierFlags.contains(.command)
                consumed = MainActor.assumeIsolated {
                    Self.shared.handleEscape(escape, windowID: windowID)
                        || Self.shared.handleReturnKey(key: key, windowID: windowID, command: command)
                        || Self.shared.handleArrowKey(key: key, windowID: windowID, shift: shift)
                }
            } else if event.type == .scrollWheel {
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
        if fullScreen { setImmersive(true) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
        if fullScreen { return finishPresenting(window) }

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
        return finishPresenting(window)
    }

    /// Deferred a runloop turn: the readout anchors to the zoom control's
    /// view, which AppKit only installs in the window hierarchy once the
    /// title bar has been laid out — synchronously it isn't there yet.
    private func finishPresenting(_ window: NSWindow) -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let model = self.model else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            self.installSizeReadout(in: window, model: model)
        }
        return true
    }

    // MARK: - Immersive mode

    private static let windowedStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// ⌃⌘F and the bar's exit button — the green button is the other way in.
    func toggleFullScreen() { setImmersive(!(model?.isFullScreen ?? false)) }

    /// The green button enters immersive mode instead of zooming.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        setImmersive(true)
        return false
    }

    private func setImmersive(_ on: Bool) {
        guard let window, let model, model.isFullScreen != on else { return }
        model.isFullScreen = on
        if on {
            windowedFrame = window.frame
            let screen = window.screen ?? NSScreen.underMouse ?? NSScreen.main
            window.toolbar?.isVisible = false
            sizeLabel?.superview?.isHidden = true
            showWallpaper(of: screen)
            window.styleMask = [.borderless]
            window.setFrame(screen?.frame ?? windowedFrame, display: true)
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            immersiveExitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { _ in
                MainActor.assumeIsolated { Self.shared.setImmersive(false) }
            }
            return
        }
        clearImmersiveExitObserver()
        wallpaperView?.isHidden = true
        let target = windowedFrame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                window.styleMask = Self.windowedStyle
                window.titleVisibility = .hidden
                window.toolbar = self.toolbar
                window.toolbarStyle = .unified
                self.toolbar?.isVisible = true
                window.setFrame(target, display: true)
                self.sizeLabel?.superview?.isHidden = false
                if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
                guard self.sizeLabel == nil, let model = self.model else { return }
                DispatchQueue.main.async { self.installSizeReadout(in: window, model: model) }
            }
        })
    }

    private func clearImmersiveExitObserver() {
        NSApp.presentationOptions = []
        guard let immersiveExitObserver else { return }
        NotificationCenter.default.removeObserver(immersiveExitObserver)
        self.immersiveExitObserver = nil
    }

    private func showWallpaper(of screen: NSScreen?) {
        guard let wallpaperView else { return }
        wallpaperView.isHidden = false
        guard wallpaperView.layer?.contents == nil else { return }
        Task { [weak wallpaperView] in
            guard let image = await ScreenshotService.currentWallpaperImage(of: screen) else { return }
            wallpaperView?.layer?.contents = image
        }
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
        stack.toolTip = String(localized: "Image size in pixels — click to copy")
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

    /// Mirrors the dirty state onto the close button's dot, re-armed after
    /// each change like the other Observation trackers here.
    private func observeUnsavedChanges() {
        withObservationTracking {
            window?.isDocumentEdited = model?.hasUnsavedProjectChanges ?? false
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.model != nil else { return }
                self.observeUnsavedChanges()
            }
        }
    }

    @objc private func copySizeAction() { model?.copySize() }

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

    /// Esc leaves the editor at any moment, saving nothing — caught here, ahead
    /// of the field editor, so it works mid-typing too.
    private func handleEscape(_ escape: Bool, windowID: ObjectIdentifier?) -> Bool {
        guard escape, let window, windowID == ObjectIdentifier(window) else { return false }
        close()
        return true
    }

    /// Return inserts a line break while a text annotation is being typed
    /// into — only clicking away commits. The field editor treats a
    /// bare Return as "submit", so it's told to insert the newline directly.
    private func handleReturnKey(key: Int?, windowID: ObjectIdentifier?, command: Bool) -> Bool {
        guard let window, let model, windowID == ObjectIdentifier(window),
              !command, model.editingTextID != nil, let key,
              [.carriageReturn, .enter].contains(NSEvent.SpecialKey(rawValue: key)),
              let editor = window.firstResponder as? NSTextView else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Arrow keys nudge the selected annotations — one point per press, ten
    /// with Shift. Handled here rather than with SwiftUI keyboard shortcuts
    /// because those fire for a plain arrow whatever the modifiers, so the
    /// Shift-modified variant never gets its own step. Returns whether the
    /// event was consumed — an arrow that moves nothing (no selection, or a
    /// text annotation being typed into) falls through to the text caret.
    private func handleArrowKey(key: Int?, windowID: ObjectIdentifier?, shift: Bool) -> Bool {
        guard let window, let model, windowID == ObjectIdentifier(window),
              let key else { return false }
        let step: (dx: CGFloat, dy: CGFloat)
        switch NSEvent.SpecialKey(rawValue: key) {
        case .leftArrow: step = (-1, 0)
        case .rightArrow: step = (1, 0)
        case .upArrow: step = (0, -1)
        case .downArrow: step = (0, 1)
        default: return false
        }
        return model.nudgeSelected(dx: step.dx, dy: step.dy, coarse: shift)
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

    /// Whether `window` is the editor — ⌘Q with it in front closes it instead
    /// of quitting, like any other window.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === self.window }

    func close() {
        model?.close()      // cleans up the temp file (guarded against re-entry)
        guard let window else { return teardown() }
        teardown()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { window.orderOut(nil) } })
    }

    /// The red button routes through the same unsaved-changes check as ⌘W.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    /// The Close button and ⌘W: a project with unsaved changes asks first, as
    /// a sheet, and closes once the user has chosen.
    func requestClose() {
        guard let window, let model, model.hasUnsavedProjectChanges else { return close() }
        askUnsavedChanges(for: model, sheetOn: window) { [weak self] decision in
            switch decision {
            case .save: guard model.saveProject() else { return }
            case .discard: break
            case .cancel: return
            }
            self?.close()
        }
    }

    /// Whether the editor can close right now — quitting from the menu asks
    /// about a dirty project the same way the close button does.
    func confirmCloseForQuit() -> Bool {
        guard let model, model.hasUnsavedProjectChanges else { return true }
        switch askUnsavedChanges(for: model) {
        case .save: return model.saveProject()
        case .discard: return true
        case .cancel: return false
        }
    }

    private enum UnsavedDecision { case save, discard, cancel }

    /// The standard "Do you want to save the changes…?" alert: Save is the
    /// default, Don't Save answers to ⌘D like TextEdit's. With a window it runs
    /// as a sheet and reports through `then`; without one it blocks and
    /// returns the answer.
    @discardableResult
    private func askUnsavedChanges(for model: EditorModel, sheetOn window: NSWindow? = nil,
                                   then: ((UnsavedDecision) -> Void)? = nil) -> UnsavedDecision {
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes made to the project “\(model.documentName)”?")
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don't Save")).keyEquivalent = "d"
        alert.buttons[2].keyEquivalentModifierMask = .command
        func decision(_ response: NSApplication.ModalResponse) -> UnsavedDecision {
            switch response {
            case .alertFirstButtonReturn: .save
            case .alertThirdButtonReturn: .discard
            default: .cancel
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { then?(decision($0)) }
            return .cancel
        }
        NSApp.activate()
        let result = decision(alert.runModal())
        then?(result)
        return result
    }
    private func clearReactivationObserver() {
        if let reactivationObserver {
            NotificationCenter.default.removeObserver(reactivationObserver)
        }
        reactivationObserver = nil
    }

    private func teardown() {
        clearReactivationObserver()
        clearImmersiveExitObserver()
        window?.delegate = nil
        window = nil
        model = nil
        toolbarDelegate = nil
        toolbar = nil
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

    /// Breathing room between the floating bars and the screen edges.
    static let paletteMargin: CGFloat = 16

    /// Wide enough for the three top-bar groups side by side, tall enough for
    /// a canvas between the bars.
    static let minContentSize = NSSize(width: 820, height: 320)

    /// Windowed, the capture opens at 1:1 (pixels ÷ capture scale → points),
    /// shrunk to fit the visible screen only when it must, never below the
    /// bars' minimum.
    private static func windowSize(for model: EditorModel) -> NSSize {
        let visible = NSScreen.underMouse?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var w = model.pixelSize.width / model.captureScale
        var h = model.pixelSize.height / model.captureScale
        guard w > 0, h > 0 else { return NSSize(width: 820, height: 620) }
        let fit = min(1, min(visible.width * 0.95 / w, visible.height * 0.95 / h))
        w *= fit
        h *= fit
        return NSSize(width: max(w.rounded(), minContentSize.width),
                      height: max(h.rounded(), minContentSize.height))
    }
}

/// Borderless while immersive, so it has to say it takes focus.
private final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        styleMask.contains(.titled) ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}

/// Supplies the editor window's toolbar items (Copy / Export / Save / Copy Text) as
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
    private static let export = NSToolbarItem.Identifier("PrtScn.export")
    private static let save = NSToolbarItem.Identifier("PrtScn.save")
    private static let copyText = NSToolbarItem.Identifier("PrtScn.copyText")
    private static let share = NSToolbarItem.Identifier("PrtScn.share")

    init(model: EditorModel) {
        self.model = model
    }

    private var ordered: [NSToolbarItem.Identifier] {
        // Crop + Pixelate + Eyedropper (all act on the image itself) sit on the
        // leading side, with the zoom −/+ group set apart next to them; on the
        // trailing side, spaces split the Copy/Export/Copy Text group from
        // project Save and from Share.
        [Self.crop, Self.pixelate, Self.eyedropper, .space, Self.zoom, .flexibleSpace,
         Self.copy, Self.export, Self.copyText, .space, Self.save, .space, Self.share]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ordered }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ordered }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.zoom {
            // One connected ( − | 100% | + ) control: a segmented control with
            // the live zoom percentage as a display-only middle segment.
            let control = ZoomSegmentedControl()
            control.segmentCount = 3
            control.trackingMode = .momentary
            control.setImage(NSImage(systemSymbolName: "minus.magnifyingglass",
                                     accessibilityDescription: String(localized: "Zoom Out")), forSegment: 0)
            control.setLabel("100%", forSegment: 1)
            control.setEnabled(false, forSegment: 1)   // a readout, not a button
            // Fixed width: no jitter as digits change, and roomy enough that
            // even "1000%" never truncates to an ellipsis.
            control.setWidth(58, forSegment: 1)
            control.setImage(NSImage(systemSymbolName: "plus.magnifyingglass",
                                     accessibilityDescription: String(localized: "Zoom In")), forSegment: 2)
            control.target = self
            control.action = #selector(zoomAction(_:))
            control.onReadoutDoubleClick = { [weak self] in self?.model.toggleActualSize() }

            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.view = control
            group.label = String(localized: "Zoom")
            group.toolTip = String(localized: "Zoom (⌘− / ⌘+, ⌘0 resets, or pinch · double-click for 100%)")
            zoomControl = control
            updateZoomLabel()
            observeZoomPercent()
            return group
        }

        if id == Self.share {
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.toolTip = String(localized: "Share")
            // Autovalidation calls our `items(for:)` every ~150ms; skip it so
            // building the share payload isn't a constant (side-effecting) cost.
            item.autovalidates = false
            item.delegate = self
            return item
        }

        if id == Self.save {
            return saveItem(id)
        }

        let spec: (symbol: String, label: String, tip: String, action: Selector)
        switch id {
        case Self.crop:
            spec = ("crop", String(localized: "Crop"), String(localized: "Crop"), #selector(cropAction))
        case Self.pixelate:
            spec = ("eye.slash", String(localized: "Pixelate"), String(localized: "Pixelate (P)"), #selector(pixelateAction))
        case Self.eyedropper:
            spec = ("eyedropper", String(localized: "Pick Color"), String(localized: "Pick Color"), #selector(eyedropperAction))
        case Self.copy:
            spec = ("document.on.document", String(localized: "Copy"), String(localized: "Copy (⌘C)"), #selector(copyAction))
        case Self.export:
            spec = ("arrow.up.document", String(localized: "Export"), String(localized: "Export as PNG (⌘E)"), #selector(exportAction))
        case Self.copyText:
            spec = ("text.viewfinder", String(localized: "OCR"), String(localized: "Copy text with OCR (⌘T)"), #selector(copyTextAction))
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

    /// Click saves the project; the dropdown offers Save As and Open.
    private func saveItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Save Project (⌘S)"), action: #selector(saveAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Save Project As… (⇧⌘S)"), action: #selector(saveAsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Open Project…"), action: #selector(openProjectAction), keyEquivalent: "").target = self

        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: String(localized: "Save"))
        item.label = String(localized: "Save")
        item.toolTip = String(localized: "Save as a project — keeps the shapes editable (⌘S)")
        item.menu = menu
        item.target = self
        item.action = #selector(saveAction)
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
    @objc private func exportAction() { model.export() }
    @objc private func saveAction() { model.saveProject() }
    @objc private func saveAsAction() { model.saveProjectAs() }
    @objc private func openProjectAction() { EditorController.shared.openProjectWithPanel() }
    @objc private func copyTextAction() { model.copyText() }

    // MARK: - Share

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        [model.sharingItem()]
    }
}

/// The ( − | 100% | + ) control. The middle segment is disabled so it reads as
/// a label, which also means the cell never tracks clicks on it — so the
/// double-click that toggles 100% ⇄ fitted is caught here, before tracking.
/// The −/+ segments are symmetric, so the readout is the centered 58pt band.
private final class ZoomSegmentedControl: NSSegmentedControl {
    var onReadoutDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let overReadout = abs(x - bounds.midX) <= width(forSegment: 1) / 2
        if event.clickCount == 2, overReadout {
            onReadoutDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
