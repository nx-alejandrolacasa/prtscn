import AppKit
import Carbon
import SwiftUI

/// SwiftUI wrapper around `RecorderView`.
struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut?
    var onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.shortcut = shortcut
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
    }
}

/// A click-to-record shortcut field.
///
/// Click it to start recording, then press a combo (at least one modifier).
/// Esc cancels, Delete/Backspace clears. We use an `NSView` rather than SwiftUI
/// because we need the raw virtual key code + modifier flags, which `keyDown`
/// gives us directly.
final class RecorderView: NSView {
    var shortcut: Shortcut? {
        didSet { refresh() }
    }
    var onChange: ((Shortcut?) -> Void)?

    private var recording = false {
        didSet { refresh() }
    }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Esc → cancel, keep existing
            window?.makeFirstResponder(nil)
        case 51, 117: // Delete / Forward-Delete → clear
            onChange?(nil)
            window?.makeFirstResponder(nil)
        default:
            let modifiers = Self.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                NSSound.beep() // require at least one modifier
                return
            }
            onChange?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
            window?.makeFirstResponder(nil)
        }
    }

    private func refresh() {
        if recording {
            label.stringValue = "Type shortcut…"
            label.textColor = .secondaryLabelColor
        } else if let shortcut {
            label.stringValue = shortcut.displayString
            label.textColor = .labelColor
        } else {
            label.stringValue = "Click to record"
            label.textColor = .secondaryLabelColor
        }
        // Resolve the dynamic colors for the current appearance — a bare
        // `.cgColor` snapshots whatever appearance happens to be current.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()   // re-resolve the layer colors for light/dark flips
    }

    /// Translate AppKit modifier flags into Carbon hotkey modifier flags.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
