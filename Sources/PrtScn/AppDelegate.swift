import AppKit

/// Classic AppKit application delegate.
///
/// In a menu-bar utility this stays small: its main job is to make the app an
/// "accessory" (no Dock icon, no main window). Later slices will use it to own
/// the preview panel and register global hotkeys.
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
    }
}
