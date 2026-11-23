import Foundation

/// The capture modes, each mapping to flags for the macOS
/// `/usr/sbin/screencapture` CLI.
enum CaptureMode: String, CaseIterable, Codable {
    case region
    case window
    case fullScreen
    case fixedSize
    case scrolling
    case text
    case previousArea

    /// Human-readable name for settings rows and menus.
    var title: String {
        switch self {
        case .region: String(localized: "Area")
        case .window: String(localized: "Window")
        case .fullScreen: String(localized: "Full Screen")
        case .fixedSize: String(localized: "Fixed Size")
        case .scrolling: String(localized: "Scrolling Area")
        case .text: String(localized: "Text (OCR)")
        case .previousArea: String(localized: "Previous Area")
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
    /// - `text`:    `-i`        a region whose recognized text goes to the
    ///                          clipboard instead of to the preview.
    /// - `previousArea`: (no flags) `ScreenshotService` replays the last
    ///                          area's rectangle through `-R`.
    /// - `scrolling`: (no flags) never shells out — `ScrollCaptureController`
    ///                          captures frames itself via ScreenCaptureKit.
    var screencaptureArgs: [String] {
        switch self {
        case .region, .text: return ["-i"]
        case .window: return ["-i", "-W"]
        case .fullScreen: return []
        case .fixedSize: return []
        case .scrolling: return []
        case .previousArea: return []
        }
    }
}
