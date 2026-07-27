import AppKit
import Observation
import SwiftUI

/// Which settings pane is selected, shared between the sidebar and detail
/// hosting controllers — plus the visit history behind the detail column's
/// back/forward chevrons, System Settings style.
@MainActor
@Observable
final class SettingsWindowModel {
    /// Panes in visit order; `cursor` is where we currently stand in it.
    private(set) var history: [SettingsPane] = [.general]
    private(set) var cursor = 0

    /// The selected pane. Assigning pushes a history entry (and drops anything
    /// ahead of the cursor, so a new choice replaces the forward trail);
    /// `goBack`/`goForward` move the cursor without recording a visit.
    var pane: SettingsPane {
        get { history[cursor] }
        set {
            guard newValue != history[cursor] else { return }
            if cursor + 1 < history.count {
                history.removeSubrange((cursor + 1)..<history.count)
            }
            history.append(newValue)
            cursor = history.count - 1
        }
    }

    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { cursor + 1 < history.count }

    func goBack() { if canGoBack { cursor -= 1 } }
    func goForward() { if canGoForward { cursor += 1 } }
}

/// The Settings window, built the way System Settings and Raycast build
/// theirs: an AppKit `NSSplitViewController` whose sidebar item supplies the
/// native full-height sidebar — its material runs from the very top of the
/// window (traffic lights float over it) to the bottom, with the standard
/// hairline separator. SwiftUI's `NavigationSplitView` can't produce this on
/// macOS 26: it renders the sidebar as a floating panel inset below the
/// title bar. The pane content itself is SwiftUI, bridged in with
/// `NSHostingController`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let model = SettingsWindowModel()

    private override init() {}

    func show() {
        // Accessory app: activate first or the window opens behind everything.
        NSApp.activate()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let split = NSSplitViewController()

        let sidebar = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: SettingsSidebar(model: model)))
        sidebar.minimumThickness = 185
        sidebar.maximumThickness = 185
        sidebar.canCollapse = false
        split.addSplitViewItem(sidebar)

        split.addSplitViewItem(NSSplitViewItem(
            viewController: NSHostingController(
                rootView: SettingsDetail(model: model))))

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "PrtScn Settings"
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        // A unified toolbar merges the title-bar region into the split view's
        // columns — that's what puts the window controls inside the sidebar
        // (HIG "split views" layout) instead of in a strip above it. It also
        // carries the pane header: a tracking separator keeps the header on
        // the detail side of the divider.
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Re-assert after the toolbar attaches; attaching one resizes content.
        window.setContentSize(NSSize(width: 640, height: 440))
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Toolbar

extension SettingsWindowController: NSToolbarDelegate {
    private static let paneHeader = NSToolbarItem.Identifier("paneHeader")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The separator tracks the sidebar's trailing edge; items after it are
        // laid out over the detail column.
        [.sidebarTrackingSeparator, Self.paneHeader]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.paneHeader else { return nil }

        let item = NSToolbarItem(itemIdentifier: identifier)
        let host = NSHostingView(rootView: SettingsPaneHeader(model: model))
        // Let the header keep its natural width as the pane name changes.
        host.sizingOptions = [.intrinsicContentSize]
        item.view = host
        item.visibilityPriority = .high
        // Otherwise AppKit wraps the whole item — chevrons *and* pane title —
        // in one glass capsule. The chevrons bring their own; the title wants
        // none.
        item.isBordered = false
        return item
    }
}
