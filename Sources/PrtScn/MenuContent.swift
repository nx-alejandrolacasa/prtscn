import SwiftUI

/// The contents of the menu-bar dropdown.
///
/// With `MenuBarExtra`'s `.menu` style, each `Button` becomes a native menu
/// item and `Divider` a separator — no AppKit `NSMenu` wiring needed.
struct MenuContent: View {
    private var updater: UpdateChecker { UpdateChecker.shared }
    private var pinned: PinnedController { PinnedController.shared }

    /// The user's configured global hotkey for `mode`, as a menu-item key
    /// equivalent — purely informative here; the Carbon registration in
    /// HotkeyManager is what actually fires the capture.
    private func hotkey(_ mode: CaptureMode) -> KeyboardShortcut? {
        SettingsStore.shared.shortcuts[mode]?.keyboardShortcut
    }

    var body: some View {
        Button {
            ScreenshotService.shared.capture(.region)
        } label: {
            Label("Capture Area", systemImage: "rectangle.dashed")
        }
        .keyboardShortcut(hotkey(.region))
        Button {
            ScreenshotService.shared.capture(.window)
        } label: {
            Label("Capture Window", systemImage: "macwindow")
        }
        .keyboardShortcut(hotkey(.window))
        Button {
            ScreenshotService.shared.capture(.fullScreen)
        } label: {
            Label("Capture Full Screen", systemImage: "display")
        }
        .keyboardShortcut(hotkey(.fullScreen))
        Button {
            ScreenshotService.shared.capture(.fixedSize)
        } label: {
            Label("Capture Fixed Size…", systemImage: "aspectratio")
        }
        .keyboardShortcut(hotkey(.fixedSize))
        Button {
            ScreenshotService.shared.capture(.scrolling)
        } label: {
            Label("Capture Scrolling Area", systemImage: "rectangle.expand.vertical")
        }
        .keyboardShortcut(hotkey(.scrolling))

        Divider()

        if pinned.hasPins {
            Button {
                pinned.closeAll()
            } label: {
                Label("Close All Pins", systemImage: "pin.slash")
            }
            Divider()
        }

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
            SettingsWindowController.shared.show()
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
