import Foundation

/// The capture modes, each mapping to flags for the macOS
/// `/usr/sbin/screencapture` CLI — the same tool the Glaze version shelled out
/// to.
enum CaptureMode: String, CaseIterable, Codable {
    case region
    case window
    case fullScreen
    case fixedSize

    /// Human-readable name for settings rows and menus.
    var title: String {
        switch self {
        case .region: "Area"
        case .window: "Window"
        case .fullScreen: "Full Screen"
        case .fixedSize: "Fixed Size"
        }
    }

    /// Flags passed to `screencapture` (the destination path is appended
    /// separately by `ScreenshotService`).
    ///
    /// - `region`:  `-i`        interactive crosshair selection.
    /// - `window`:  `-i -W`     interactive window picker; omitting `-o` keeps
    ///                          the window's drop shadow + transparent padding.
    /// - `full`:    (no flags)  capture all displays immediately.
    /// - `fixed`:   (no flags)  the `-R x,y,w,h` rect is appended by
    ///                          `ScreenshotService` once the overlay is clicked.
    var screencaptureArgs: [String] {
        switch self {
        case .region: return ["-i"]
        case .window: return ["-i", "-W"]
        case .fullScreen: return []
        case .fixedSize: return []
        }
    }
}
