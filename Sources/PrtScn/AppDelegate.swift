import AppKit

/// Classic AppKit application delegate.
///
/// In a menu-bar utility this stays small: its main job is to make the app an
/// "accessory" (no Dock icon, no main window). Later slices will use it to own
/// the preview panel and register global hotkeys.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `.accessory` = lives in the menu bar only, no Dock icon and no
        // app menu. This is the native equivalent of Glaze's
        // `activationPolicy: "accessory"`.
        NSApp.setActivationPolicy(.accessory)

        // Apply the saved Light/Dark/Auto preference on launch.
        SettingsStore.shared.applyAppearance()

        // Register the global capture shortcuts.
        HotkeyManager.shared.reloadFromSettings()
    }
}
