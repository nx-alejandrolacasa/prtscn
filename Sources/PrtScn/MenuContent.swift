import SwiftUI

/// The contents of the menu-bar dropdown.
///
/// With `MenuBarExtra`'s `.menu` style, each `Button` becomes a native menu
/// item and `Divider` a separator — no AppKit `NSMenu` wiring needed.
struct MenuContent: View {
    /// SwiftUI-provided action to open the `Settings` scene (macOS 14+).
    @Environment(\.openSettings) private var openSettings

    private var updater: UpdateChecker { UpdateChecker.shared }

    var body: some View {
        Button {
            ScreenshotService.shared.capture(.region)
        } label: {
            Label("Capture Area", systemImage: "rectangle.dashed")
        }
        Button {
            ScreenshotService.shared.capture(.window)
        } label: {
            Label("Capture Window", systemImage: "macwindow")
        }
        Button {
            ScreenshotService.shared.capture(.fullScreen)
        } label: {
            Label("Capture Full Screen", systemImage: "display")
        }

        Divider()

        // Surfaced by the quiet launch-time check — most users never open
        // Settings → About, so the update offer has to live where they look.
        if updater.phase == .available, let release = updater.latest {
            Button {
                Task { await updater.installLatest() }
            } label: {
                Label("Update to \(release.version)…", systemImage: "arrow.down.circle")
            }
            Divider()
        }

        Button {
            // Accessory (menu-bar) apps aren't active by default, so the
            // Settings window would open behind everything — or appear not to
            // open at all. Activate first, then open it.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit PrtScn", systemImage: "power")
        }
    }
}
