import SwiftUI

/// The contents of the menu-bar dropdown.
///
/// With `MenuBarExtra`'s `.menu` style, each `Button` becomes a native menu
/// item and `Divider` a separator — no AppKit `NSMenu` wiring needed.
struct MenuContent: View {
    /// SwiftUI-provided action to open the `Settings` scene (macOS 14+).
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Capture Region") {
            ScreenshotService.shared.capture(.region)
        }
        Button("Capture Window") {
            ScreenshotService.shared.capture(.window)
        }
        Button("Capture Full Screen") {
            ScreenshotService.shared.capture(.fullScreen)
        }

        Divider()

        Button("Settings…") {
            // Accessory (menu-bar) apps aren't active by default, so the
            // Settings window would open behind everything — or appear not to
            // open at all. Activate first, then open it.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        Button("Quit PrtScn") {
            NSApplication.shared.terminate(nil)
        }
    }
}
