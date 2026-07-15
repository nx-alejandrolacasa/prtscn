import SwiftUI

/// The app entry point.
///
/// SwiftUI's `App` protocol replaces the old `main.swift` + storyboard setup.
/// `@main` marks this as the program's starting point. A SwiftUI `App` is a
/// collection of `Scene`s — here a menu-bar item and a Settings window.
@main
struct PrtScnApp: App {
    /// Bridges in a classic AppKit `NSApplicationDelegate`. We need it to set
    /// the activation policy (menu-bar app, no Dock icon) and, later, to own
    /// the preview panel and global hotkeys — things SwiftUI alone can't do.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The dev variant (bundle id suffixed ".dev" by build.sh) runs alongside
    /// the installed app — give it a visibly different menu-bar icon.
    private var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    var body: some Scene {
        // The menu-bar item. `.menu` style makes it a classic dropdown menu
        // (vs. a popover window). The SF Symbol is the menu-bar icon.
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarIcon(restingIcon: isDevBuild ? "photo.trianglebadge.exclamationmark" : "photo.on.rectangle.angled")
        }
        .menuBarExtraStyle(.menu)

        // The Settings window is NOT a SwiftUI scene: the System Settings
        // look (full-height sidebar with the traffic lights floating over
        // it) needs AppKit's NSSplitViewController — see SettingsWindow.swift.
    }
}

/// The menu-bar icon, briefly swapped to a checkmark-badged photo right after a
/// capture so even silent captures (shutter sound off, eyes away from the
/// preview) get visible feedback.
private struct MenuBarIcon: View {
    let restingIcon: String
    private let state = MenuBarState.shared

    var body: some View {
        Image(systemName: state.flashingCapture ? "photo.badge.checkmark" : restingIcon)
    }
}
