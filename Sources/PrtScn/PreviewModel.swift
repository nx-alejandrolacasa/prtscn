import AppKit
import Observation

/// Observable state + behavior for one preview card.
///
/// `@Observable` (the modern replacement for `ObservableObject`) lets SwiftUI
/// views automatically re-render when the properties they read change — here,
/// the countdown progress and the currently hovered action.
@MainActor
@Observable
final class PreviewModel {
    let image: NSImage
    let imageURL: URL
    let timeout: Double
    /// Backing scale measured at capture time; passed through to the editor for
    /// 1:1 sizing.
    let captureScale: CGFloat
    /// The capture before window-background compositing (nil when no composite
    /// ran). Pin displays this so a pinned window floats bare, without its
    /// margins/solid/wallpaper backdrop.
    let pristineImage: NSImage?

    /// Seconds left before auto-dismiss; drives the countdown bar.
    var remaining: Double

    /// True while the pointer is over the card — pauses the countdown.
    var isHovering = false

    /// The action under the pointer, for the hover hint pill (nil = none).
    var hoveredAction: PreviewAction?

    /// Called when the card should be torn down (set by the controller).
    var onClose: (() -> Void)?

    private var handled = false
    private var closed = false

    init(image: NSImage, imageURL: URL, timeout: Double = 5.0, captureScale: CGFloat,
         pristineImage: NSImage? = nil) {
        self.image = image
        self.imageURL = imageURL
        self.timeout = timeout
        self.remaining = timeout
        self.captureScale = captureScale
        self.pristineImage = pristineImage
    }

    /// 1 → 0, for the width of the countdown bar.
    var progress: Double {
        timeout > 0 ? remaining / timeout : 1
    }

    /// Counts down in small steps, pausing while hovered. Driven by the view's
    /// `.task`, so it's automatically cancelled when the card disappears.
    /// A timeout of `0` means "Never" — the card stays until the user acts.
    func runCountdown() async {
        guard timeout > 0 else { return }
        let step = 0.05
        while remaining > 0 {
            try? await Task.sleep(for: .seconds(step))
            if Task.isCancelled { return }
            if isHovering { continue }      // paused
            remaining = max(0, remaining - step)
        }
        dismiss()
    }

    // MARK: - Actions

    func perform(_ action: PreviewAction) {
        switch action {
        case .edit:
            EditorController.shared.show(imageURL: imageURL, captureScale: captureScale)
            handled = true
            close(cleanup: false)           // the editor now owns the temp file
        case .copy:
            ScreenshotService.shared.copyToClipboard(imageURL)
            handled = true
            close(cleanup: true)
        case .ocr:
            ScreenshotService.shared.copyText(in: image)
            handled = true
            close(cleanup: true)
        case .save:
            ScreenshotService.shared.save(imageURL)
            handled = true
            close(cleanup: true)
        case .pin:
            PinnedController.shared.pin(image: pristineImage ?? image, imageURL: imageURL,
                                        captureScale: captureScale)
            handled = true
            close(cleanup: false)           // the pin now owns the temp file
        case .discard:
            handled = true
            close(cleanup: true)    // delete the temp capture, save nothing
        }
    }

    /// Auto-dismiss (timeout). An untouched capture gets the user's configured
    /// default action (Save by default) so it isn't silently lost. (Esc is
    /// different: it explicitly discards — see PreviewCard's escape handler.)
    func dismiss() {
        guard !handled else {
            close(cleanup: true)
            return
        }
        switch SettingsStore.shared.defaultAction {
        case .save:
            ScreenshotService.shared.save(imageURL)
            close(cleanup: true)
        case .copy:
            ScreenshotService.shared.copyToClipboard(imageURL)
            close(cleanup: true)
        case .edit:
            EditorController.shared.show(imageURL: imageURL, captureScale: captureScale)
            close(cleanup: false)   // the editor now owns the temp file
        case .discard:
            close(cleanup: true)    // delete temp, save nothing
        }
    }

    private func close(cleanup: Bool) {
        guard !closed else { return }
        closed = true
        if cleanup {
            ScreenshotService.shared.cleanup(imageURL)
        }
        onClose?()
    }
}
