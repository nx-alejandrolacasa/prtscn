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

    /// `asksFirst` adds the ellipsis of an item that opens a dialog.
    private func captureItem(_ mode: CaptureMode, _ symbol: String, asksFirst: Bool = false) -> some View {
        Button {
            ScreenshotService.shared.capture(mode)
        } label: {
            Label(mode.title + (asksFirst ? "…" : ""), systemImage: symbol)
        }
        .keyboardShortcut(hotkey(mode))
    }

    var body: some View {
        // macOS menu items default to a title-only label style, which drops
        // the SF Symbol; opt every item into icon + title explicitly.
        Group {
            // One "Capture" heading instead of the word on every item, and
            // the everyday modes apart from the specialised ones.
            Section("Capture") {
                captureItem(.region, "rectangle.dashed")
                captureItem(.previousArea, "repeat")
                captureItem(.window, "macwindow")
                captureItem(.fullScreen, "display")
            }
            Section {
                captureItem(.fixedSize, "aspectratio", asksFirst: true)
                captureItem(.scrolling, "rectangle.expand.vertical")
                captureItem(.text, "text.viewfinder")
            }

            Divider()

            Button {
                BlankCanvas.open()
            } label: {
                Label("New Blank Canvas", systemImage: "plus.rectangle")
            }
            Button {
                EditorController.shared.openFileWithPanel()
            } label: {
                Label("Open File…", systemImage: "arrow.up.forward.square")
            }
            Button {
                LastCapture.shared.reopen()
            } label: {
                Label("Reopen Last Capture", systemImage: "arrow.uturn.backward")
            }
            .disabled(!LastCapture.shared.exists)

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
        .labelStyle(.titleAndIcon)
    }
}
