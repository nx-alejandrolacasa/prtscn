import Foundation
import Observation

/// Drives the menu-bar icon's brief "shot taken" flash.
///
/// The preview card is the main capture feedback, but it appears at the
/// cursor — if you're looking elsewhere (or capture with the shutter sound
/// off) it's easy to miss. Flashing the menu-bar icon gives a second,
/// always-visible confirmation.
@MainActor
@Observable
final class MenuBarState {
    static let shared = MenuBarState()

    /// True while the icon should show its "captured" variant.
    private(set) var flashingCapture = false

    private var flashTask: Task<Void, Never>?

    private init() {}

    /// Flash the icon for a moment. Rapid captures restart the timer instead
    /// of stacking flashes.
    func flashCaptureFeedback() {
        flashTask?.cancel()
        flashingCapture = true
        flashTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            flashingCapture = false
        }
    }
}
