import Carbon
import SwiftUI

/// A keyboard shortcut as the Carbon hotkey API wants it: a virtual key code
/// plus a Carbon modifier-flags bitmask (`cmdKey`, `optionKey`, …).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// e.g. "⌘⌥1" — modifier glyphs in canonical macOS order, then the key.
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyLabel(for: keyCode)
        return result
    }

    /// Display label for a virtual key code: special keys get their fixed
    /// glyph; character keys are translated through the *current* keyboard
    /// layout (an AZERTY user sees "A" where a US layout has "Q"). Computed
    /// per call so labels follow layout switches.
    static func keyLabel(for keyCode: UInt32) -> String {
        Self.specialKeyLabels[keyCode] ?? Self.characterKeyLabel(for: keyCode) ?? "·"
    }

    /// Keys whose label is a glyph or name, not a layout-dependent character.
    /// (Carbon `kVK_*`.)
    static let specialKeyLabels: [UInt32: String] = [
        // Editing / whitespace
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// US-ANSI fallback for character keys, used only when `UCKeyTranslate`
    /// can't produce a character (e.g. a layout without Unicode data).
    static let fallbackKeyLabels: [UInt32: String] = [
        // Digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Letters
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G",
        4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
        31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
        9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
    ]

    private static func characterKeyLabel(for keyCode: UInt32) -> String? {
        layoutKeyLabel(for: keyCode) ?? fallbackKeyLabels[keyCode]
    }

    /// The character the current keyboard layout produces for a bare press of
    /// `keyCode` (no modifiers), uppercased for display. `nil` when the layout
    /// has no Unicode data or the key yields no printable character.
    private static func layoutKeyLabel(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
        guard let layoutPtr = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0   // UniCharCount (not exported to Swift on the CLT SDK)
        let status = layoutPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout,
                           UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay),
                           0,   // no modifiers: the raw key
                           UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask),
                           &deadKeyState,
                           chars.count,
                           &length,
                           &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: chars, count: Int(length))
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// The SwiftUI equivalent, for displaying the hotkey on menu items.
    /// `nil` when the key has no `KeyEquivalent` (e.g. function keys) — the
    /// menu item then simply shows no shortcut.
    var keyboardShortcut: KeyboardShortcut? {
        guard let key = keyEquivalent else { return nil }
        var eventModifiers: SwiftUI.EventModifiers = []   // Carbon has its own EventModifiers
        if modifiers & UInt32(controlKey) != 0 { eventModifiers.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { eventModifiers.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { eventModifiers.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { eventModifiers.insert(.command) }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Space: .space
        case kVK_Return: .return
        case kVK_Tab: .tab
        case kVK_Escape: .escape
        case kVK_Delete: .delete
        case kVK_ForwardDelete: .deleteForward
        case kVK_LeftArrow: .leftArrow
        case kVK_RightArrow: .rightArrow
        case kVK_DownArrow: .downArrow
        case kVK_UpArrow: .upArrow
        default:
            if let label = Self.characterKeyLabel(for: keyCode), label.count == 1,
               let character = label.lowercased().first {
                KeyEquivalent(character)
            } else {
                nil
            }
        }
    }
}
