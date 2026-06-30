import SwiftUI

/// The three actions offered on the preview card, plus their icon, label, and
/// keyboard shortcut.
enum PreviewAction: CaseIterable, Identifiable {
    case copy
    case edit
    case save
    case ocr

    var id: Self { self }

    var label: String {
        switch self {
        case .edit: "Edit"
        case .copy: "Copy"
        case .ocr: "Copy Text"
        case .save: "Save"
        }
    }

    /// SF Symbol name for the toolbar button.
    var systemImage: String {
        switch self {
        case .edit: "pencil"
        case .copy: "doc.on.doc"
        case .ocr: "text.viewfinder"
        case .save: "square.and.arrow.down"
        }
    }

    /// Glyphs shown in the hover hint pill.
    var shortcutHint: String {
        switch self {
        case .edit: "⏎"
        case .copy: "⌘C"
        case .ocr: "⌘T"
        case .save: "⌘S"
        }
    }

    /// The SwiftUI keyboard shortcut that triggers this action while the
    /// preview is focused: Enter → Edit, ⌘C → Copy, ⌘T → Copy Text (OCR),
    /// ⌘S → Save.
    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .edit: KeyboardShortcut(.return, modifiers: [])
        case .copy: KeyboardShortcut("c", modifiers: .command)
        case .ocr: KeyboardShortcut("t", modifiers: .command)
        case .save: KeyboardShortcut("s", modifiers: .command)
        }
    }
}
