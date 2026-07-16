import AppKit
import Observation
import SwiftUI

/// Which settings pane is selected, shared between the sidebar and detail
/// hosting controllers.
@MainActor
@Observable
final class SettingsWindowModel {
    var pane: SettingsPane = .general
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
        // An empty unified toolbar merges the title-bar region into the split
        // view's columns — that's what puts the window controls inside the
        // sidebar (HIG "split views" layout) instead of in a strip above it.
        window.toolbar = NSToolbar()
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
