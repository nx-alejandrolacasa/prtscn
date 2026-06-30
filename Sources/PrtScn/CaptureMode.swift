import Foundation

/// The three capture modes, each mapping to flags for the macOS
/// `/usr/sbin/screencapture` CLI — the same tool the Glaze version shelled out
/// to.
enum CaptureMode: String, CaseIterable, Codable {
    case region
    case window
    case fullScreen

    /// Human-readable name for settings rows and menus.
    var title: String {
        switch self {
        case .region: "Region"
        case .window: "Window"
        case .fullScreen: "Full Screen"
        }
    }

    /// Flags passed to `screencapture` (the destination path is appended
    /// separately by `ScreenshotService`).
    ///
    /// - `region`:  `-i`        interactive crosshair selection.
    /// - `window`:  `-i -W`     interactive window picker; omitting `-o` keeps
    ///                          the window's drop shadow + transparent padding.
    /// - `full`:    (no flags)  capture all displays immediately.
    var screencaptureArgs: [String] {
        switch self {
        case .region: return ["-i"]
        case .window: return ["-i", "-W"]
        case .fullScreen: return []
        }
    }
}
