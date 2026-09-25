import AppKit
import SwiftUI

/// How a *window* capture's surrounding area is rendered. Region and
/// full-screen captures ignore this — only window shots have a shadow/margin.
///
/// - `margins`:    screencapture's default — the window's drop shadow on a
///                 transparent surround (what we had before).
/// - `solidColor`: the same shot composited over a solid color.
/// - `wallpaper`:  composited over the current desktop picture.
/// - `trimShadow`: `-o` drops the shadow, cropping tight to the window.
enum WindowBackground: String, CaseIterable, Identifiable, Codable {
    case margins
    case solidColor
    case wallpaper
    case trimShadow

    var id: Self { self }

    var label: String {
        switch self {
        case .margins: String(localized: "With margins")
        case .solidColor: String(localized: "Solid color")
        case .wallpaper: String(localized: "Desktop background")
        case .trimShadow: String(localized: "Without margins")
        }
    }

    /// Extra flags for `screencapture`. Only Trim Shadow changes how the shot is
    /// taken (`-o` = no window shadow); the rest start from the default capture.
    var extraCaptureArgs: [String] {
        self == .trimShadow ? ["-o"] : []
    }

    /// True when the captured PNG needs a background drawn behind it afterwards.
    var needsComposite: Bool {
        self == .solidColor || self == .wallpaper
    }
}

// MARK: - Color ↔ hex

/// Lets us persist the solid-color choice as a simple `#RRGGBB` string in
/// UserDefaults and round-trip it back into a SwiftUI `Color`.
extension Color {
    init(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: string).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var hexString: String { NSColor(self).hexString }
}

extension NSColor {
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? .black
        // Wide-gamut (P3) colors can convert to sRGB components outside 0…1;
        // clamp so saturated colors can't format as malformed hex.
        func byte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X",
                      byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
