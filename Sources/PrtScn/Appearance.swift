import AppKit

/// App appearance preference: Auto / Light / Dark.
enum Appearance: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The `NSAppearance` to apply — `nil` means "follow the system" (Auto).
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
