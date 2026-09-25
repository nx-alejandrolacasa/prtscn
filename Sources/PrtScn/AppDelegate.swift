import AppKit

/// Classic AppKit application delegate: makes the app an "accessory" (no
/// Dock icon, no main window), registers the global hotkeys, opens `.prtscn`
/// projects, and offers back a canvas a crash left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app by default (`.accessory`: no Dock icon, no app menu),
        // but the Dock-icon setting can keep it `.regular` — always, or only
        // while the editor is open.
        SettingsStore.shared.applyDockIcon()

        // Apply the saved Light/Dark/Auto preference on launch.
        SettingsStore.shared.applyAppearance()

        // Register the global capture shortcuts.
        HotkeyManager.shared.reloadFromSettings()

        // Quiet daily update check; if a newer release exists, the menu and
        // the About tab offer the update.
        Task { await UpdateChecker.shared.checkAutomatically() }

        CanvasRecovery.offerRecoveryAtLaunch()
    }

    /// A deliberate quit already asked about unsaved projects; closing the
    /// editor drops its crash snapshot so the next launch doesn't offer it.
    func applicationWillTerminate(_ notification: Notification) {
        EditorController.shared.close()
        CanvasRecovery.waitForPendingWrites()
    }

    /// Finder double-click / drag-to-icon on a `.prtscn` project. One editor
    /// window, so only the last URL is opened.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last(where: { $0.pathExtension == "prtscn" }) else { return }
        EditorController.shared.open(projectURL: url)
    }

    /// ⌘Q with a window in front (editor, Settings, …) closes that window
    /// instead of quitting — the app lives in the menu bar; only its explicit
    /// Quit item (a click, not a key press) and system shutdown end it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "q",
              let window = NSApp.keyWindow, window.styleMask.contains(.closable)
        else { return EditorController.shared.confirmCloseForQuit() ? .terminateNow : .terminateCancel }
        window.performClose(nil)
        return .terminateCancel
    }
}
