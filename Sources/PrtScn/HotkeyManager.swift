import AppKit
import Carbon

/// Registers system-wide capture shortcuts via Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the right tool here: they fire no matter which app is
/// focused and — unlike a `CGEventTap` — need **no** Accessibility permission.
/// One shared keyboard event handler routes every hotkey press back to us by id.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Four-char signature ("PTSC") tagging our hotkeys.
    static let signature: OSType = 0x5054_5343

    private var registrations: [(ref: EventHotKeyRef, id: UInt32)] = []
    private var idToMode: [UInt32: CaptureMode] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    /// (Re)registers every shortcut from the settings store. Call at launch and
    /// whenever the shortcuts change.
    func reloadFromSettings() {
        installHandlerIfNeeded()
        unregisterAll()
        for (mode, shortcut) in SettingsStore.shared.shortcuts {
            register(mode: mode, shortcut: shortcut)
        }
    }

    /// Called (on the main actor) by the C event handler when a hotkey fires.
    func handleHotKey(id: UInt32) {
        guard let mode = idToMode[id] else { return }
        ScreenshotService.shared.capture(mode)
    }

    // MARK: - Registration

    private func register(mode: CaptureMode, shortcut: Shortcut) {
        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            registrations.append((ref, id))
            idToMode[id] = mode
        } else {
            // Most common cause: the combo is already taken (by the system or
            // another app). We log rather than fail loudly.
            NSLog("[PrtScn] could not register \(shortcut.displayString) for \(mode.rawValue) (status \(status))")
        }
    }

    private func unregisterAll() {
        for registration in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        idToMode.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, nil)
        handlerInstalled = true
    }
}

/// C-compatible event handler. Pulls the hotkey id out of the event and hands it
/// to the manager on the main actor.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    Task { @MainActor in
        HotkeyManager.shared.handleHotKey(id: id)
    }
    return noErr
}
