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

    var body: some Scene {
        // The menu-bar item. `.menu` style makes it a classic dropdown menu
        // (vs. a popover window). The SF Symbol is the menu-bar icon.
        MenuBarExtra("PrtScn", systemImage: "camera.viewfinder") {
            MenuContent()
        }
        .menuBarExtraStyle(.menu)

        // The Settings window — gets ⌘, support and the standard chrome for free.
        Settings {
            SettingsView()
        }
    }
}
