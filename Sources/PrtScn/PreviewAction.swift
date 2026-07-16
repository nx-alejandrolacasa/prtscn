import SwiftUI

/// The actions offered on the preview card, plus their icon, label, and
/// keyboard shortcut. Raw values persist the user's toolbar layout
/// (order + hidden set) in Settings → Preview.
enum PreviewAction: String, CaseIterable, Identifiable {
    case edit
    case copy
    case save
    case ocr
    case pin
    case discard

    var id: Self { self }

    var label: String {
        switch self {
        case .edit: "Edit"
        case .copy: "Copy"
        case .ocr: "OCR"
        case .save: "Save"
        case .pin: "Pin"
        case .discard: "Discard"
        }
    }

    /// SF Symbol name for the toolbar button.
    var systemImage: String {
        switch self {
        case .edit: "pencil.and.outline"
        case .copy: "doc.on.doc"
        case .ocr: "text.viewfinder"
        case .save: "square.and.arrow.down"
        case .pin: "pin"
        case .discard: "trash"
        }
    }

    /// Glyphs shown in the hover hint pill.
    var shortcutHint: String {
        switch self {
        case .edit: "⏎"
        case .copy: "⌘C"
        case .ocr: "⌘T"
        case .save: "⌘S"
        case .pin: "⌘P"
        case .discard: "⌫"
        }
    }

    /// The SwiftUI keyboard shortcut that triggers this action while the
    /// preview is focused: Enter → Edit, ⌘C → Copy, ⌘T → OCR, ⌘S → Save,
    /// ⌘P → Pin, Delete → Discard.
    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .edit: KeyboardShortcut(.return, modifiers: [])
        case .copy: KeyboardShortcut("c", modifiers: .command)
        case .ocr: KeyboardShortcut("t", modifiers: .command)
        case .save: KeyboardShortcut("s", modifiers: .command)
        case .pin: KeyboardShortcut("p", modifiers: .command)
        case .discard: KeyboardShortcut(.delete, modifiers: [])
        }
    }
}
