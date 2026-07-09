import Foundation

/// Visual style of the floating preview (Settings → Capture → "Preview style").
///
/// Both styles share the same behavior — actions, keyboard shortcuts,
/// countdown, drag-out — and only arrange the pieces differently.
enum PreviewStyle: String, CaseIterable, Identifiable {
    /// The classic pieces de-fused into separate floating glass islands.
    /// Declared first so it leads the picker; it's also the default.
    case islands
    /// The original Shottr-style card: thumbnail + bar + toolbar in one glass slab.
    case classic

    var id: Self { self }

    /// Catchy display names: one island vs. many.
    var label: String {
        switch self {
        case .classic: "Island"
        case .islands: "Archipelago"
        }
    }
}
