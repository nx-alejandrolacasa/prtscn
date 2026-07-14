import AppKit
import Carbon
import Observation
import ServiceManagement
import SwiftUI

/// App-wide settings, persisted to `UserDefaults` and observable by SwiftUI.
///
/// Each property writes itself back to `UserDefaults` (and applies any live
/// side effect) in its `didSet`. Property observers don't fire during `init`,
/// so loading saved values in `init` doesn't trigger spurious re-saves or
/// re-registrations.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    /// Register/unregister the app as a macOS login item.
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Auto / Light / Dark — applied to the whole app immediately.
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Seconds before the preview auto-dismisses; `0` means "Never".
    var previewTimeout: Double {
        didSet { defaults.set(previewTimeout, forKey: Keys.previewTimeout) }
    }

    /// Visual style of the floating preview: Archipelago (floating islands,
    /// the default) or Island (the classic one-slab card).
    var previewStyle: PreviewStyle {
        didSet { defaults.set(previewStyle.rawValue, forKey: Keys.previewStyle) }
    }

    /// What to do with an untouched capture when the preview is dismissed.
    var defaultAction: DefaultAction {
        didSet { defaults.set(defaultAction.rawValue, forKey: Keys.defaultAction) }
    }

    /// Folder where captures are saved.
    var saveFolderPath: String {
        didSet { defaults.set(saveFolderPath, forKey: Keys.saveFolder) }
    }

    /// How the area around a *window* capture is rendered (margins / solid /
    /// wallpaper / trimmed).
    var windowBackground: WindowBackground {
        didSet { defaults.set(windowBackground.rawValue, forKey: Keys.windowBackground) }
    }

    /// The fill used when `windowBackground == .solidColor`.
    var windowBackgroundColor: Color {
        didSet { defaults.set(windowBackgroundColor.hexString, forKey: Keys.windowBackgroundColor) }
    }

    /// Whether the editor closes automatically after Copy / Save / Copy Text.
    var closeEditorAfterAction: Bool {
        didSet { defaults.set(closeEditorAfterAction, forKey: Keys.closeEditorAfterAction) }
    }

    /// Last-used annotation drawing color, remembered across editor sessions.
    var editorColor: Color {
        didSet { defaults.set(editorColor.hexString, forKey: Keys.editorColor) }
    }

    /// Last-used text font design.
    var editorFontDesign: FontDesign {
        didSet { defaults.set(editorFontDesign.rawValue, forKey: Keys.editorFontDesign) }
    }

    /// The unit the measure tool's labels report distances in.
    var measureUnit: MeasureUnit {
        didSet { defaults.set(measureUnit.rawValue, forKey: Keys.measureUnit) }
    }

    /// Whether the measure tool shows the magnifier loupe while aiming/dragging.
    var measureLoupe: Bool {
        didSet { defaults.set(measureLoupe, forKey: Keys.measureLoupe) }
    }

    /// Whether full-screen captures include the mouse pointer
    /// (`screencapture -C`; interactive modes ignore the flag).
    var includePointer: Bool {
        didSet { defaults.set(includePointer, forKey: Keys.includePointer) }
    }

    /// Whether the system shutter sound plays on capture (`-x` silences it).
    var shutterSound: Bool {
        didSet { defaults.set(shutterSound, forKey: Keys.shutterSound) }
    }

    /// Pixel density of saved captures from HiDPI displays: native, downscaled
    /// to standard resolution, or both files (`name.png` + `name@2x.png`-style).
    var saveResolution: SaveResolution {
        didSet { defaults.set(saveResolution.rawValue, forKey: Keys.saveResolution) }
    }

    /// Pixel density of captures copied to the clipboard from HiDPI displays.
    var copyResolution: CopyResolution {
        didSet { defaults.set(copyResolution.rawValue, forKey: Keys.copyResolution) }
    }

    /// Filename prefix for saved/shared captures ("PrtScn 2026-01-01 at ….png").
    var filenamePrefix: String {
        didSet { defaults.set(filenamePrefix, forKey: Keys.filenamePrefix) }
    }

    /// `filenamePrefix` made safe for a filename: trimmed, path separators
    /// stripped, and never empty.
    var sanitizedFilenamePrefix: String {
        let cleaned = filenamePrefix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "PrtScn" : cleaned
    }

    /// Whether the editor reopens with the last-used tool (vs. always Arrow).
    var rememberLastTool: Bool {
        didSet { defaults.set(rememberLastTool, forKey: Keys.rememberLastTool) }
    }

    /// The last-used editor tool, kept fresh by `EditorModel`.
    var editorTool: EditTool {
        didSet { defaults.set(editorTool.rawValue, forKey: Keys.editorTool) }
    }

    /// Last-used fixed-size capture dimensions, in `fixedSizeUnit` units.
    var fixedSizeWidth: Int {
        didSet { defaults.set(fixedSizeWidth, forKey: Keys.fixedSizeWidth) }
    }

    var fixedSizeHeight: Int {
        didSet { defaults.set(fixedSizeHeight, forKey: Keys.fixedSizeHeight) }
    }

    /// Whether the fixed-size dimensions mean output pixels or screen points.
    var fixedSizeUnit: FixedSizeUnit {
        didSet { defaults.set(fixedSizeUnit.rawValue, forKey: Keys.fixedSizeUnit) }
    }

    /// Global capture shortcuts, per mode. Saving re-registers the hotkeys.
    var shortcuts: [CaptureMode: Shortcut] {
        didSet {
            persistShortcuts()
            HotkeyManager.shared.reloadFromSettings()
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "appearance"
        static let previewTimeout = "previewTimeout"
        static let previewStyle = "previewStyle"
        static let defaultAction = "defaultAction"
        static let saveFolder = "saveFolder"
        static let shortcuts = "shortcuts"
        static let windowBackground = "windowBackground"
        static let windowBackgroundColor = "windowBackgroundColor"
        static let closeEditorAfterAction = "closeEditorAfterAction"
        static let editorColor = "editorColor"
        static let editorFontDesign = "editorFontDesign"
        static let measureUnit = "measureUnit"
        static let measureLoupe = "measureLoupe"
        static let includePointer = "includePointer"
        static let shutterSound = "shutterSound"
        static let saveResolution = "saveResolution"
        static let copyResolution = "copyResolution"
        static let filenamePrefix = "filenamePrefix"
        static let rememberLastTool = "rememberLastTool"
        static let editorTool = "editorTool"
        static let fixedSizeWidth = "fixedSizeWidth"
        static let fixedSizeHeight = "fixedSizeHeight"
        static let fixedSizeUnit = "fixedSizeUnit"
    }

    /// Default annotation color — system red.
    static let defaultEditorColor = "#FF3B30"

    /// Default solid-color background — a neutral dark slate.
    static let defaultWindowBackgroundColor = "#2C2E33"

    private init() {
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .auto
        previewTimeout = defaults.object(forKey: Keys.previewTimeout) as? Double ?? 5.0
        previewStyle = PreviewStyle(rawValue: defaults.string(forKey: Keys.previewStyle) ?? "") ?? .islands
        defaultAction = DefaultAction(rawValue: defaults.string(forKey: Keys.defaultAction) ?? "") ?? .save
        saveFolderPath = defaults.string(forKey: Keys.saveFolder) ?? Self.defaultSaveFolder
        windowBackground = WindowBackground(rawValue: defaults.string(forKey: Keys.windowBackground) ?? "") ?? .margins
        windowBackgroundColor = Color(hex: defaults.string(forKey: Keys.windowBackgroundColor) ?? Self.defaultWindowBackgroundColor)
        closeEditorAfterAction = defaults.object(forKey: Keys.closeEditorAfterAction) as? Bool ?? true
        editorColor = Color(hex: defaults.string(forKey: Keys.editorColor) ?? Self.defaultEditorColor)
        editorFontDesign = FontDesign(rawValue: defaults.string(forKey: Keys.editorFontDesign) ?? "") ?? .sans
        measureUnit = MeasureUnit(rawValue: defaults.string(forKey: Keys.measureUnit) ?? "") ?? .points
        measureLoupe = defaults.object(forKey: Keys.measureLoupe) as? Bool ?? true
        includePointer = defaults.object(forKey: Keys.includePointer) as? Bool ?? false
        shutterSound = defaults.object(forKey: Keys.shutterSound) as? Bool ?? true
        saveResolution = SaveResolution(rawValue: defaults.string(forKey: Keys.saveResolution) ?? "") ?? .native
        copyResolution = CopyResolution(rawValue: defaults.string(forKey: Keys.copyResolution) ?? "") ?? .native
        filenamePrefix = defaults.string(forKey: Keys.filenamePrefix) ?? "PrtScn"
        rememberLastTool = defaults.object(forKey: Keys.rememberLastTool) as? Bool ?? true
        editorTool = EditTool(rawValue: defaults.string(forKey: Keys.editorTool) ?? "") ?? .arrow
        fixedSizeWidth = defaults.object(forKey: Keys.fixedSizeWidth) as? Int ?? 1280
        fixedSizeHeight = defaults.object(forKey: Keys.fixedSizeHeight) as? Int ?? 720
        fixedSizeUnit = FixedSizeUnit(rawValue: defaults.string(forKey: Keys.fixedSizeUnit) ?? "") ?? .pixels
        shortcuts = Self.loadShortcuts(from: defaults) ?? Self.defaultShortcuts
        // Reflect the real system login-item state rather than a stored guess.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - Shortcuts

    /// ⌘⌥1 / ⌘⌥2 / ⌘⌥3 / ⌘⌥4 (avoiding macOS's ⌘⇧3/4/5). The dev build — its
    /// own bundle id, run alongside the installed app — adds ⇧ so the two don't
    /// register the same global hotkeys. (Each variant persists its own
    /// shortcuts anyway; these are just the first-run defaults.)
    static let defaultShortcuts: [CaptureMode: Shortcut] = {
        let modifiers = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            ? UInt32(cmdKey | optionKey | shiftKey)
            : UInt32(cmdKey | optionKey)
        return [
            .region: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers),
            .window: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers),
            .fullScreen: Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers),
            .fixedSize: Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers),
        ]
    }()

    private func persistShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.shortcuts)
        }
    }

    private static func loadShortcuts(from defaults: UserDefaults) -> [CaptureMode: Shortcut]? {
        guard let data = defaults.data(forKey: Keys.shortcuts),
              let raw = try? JSONDecoder().decode([String: Shortcut].self, from: data)
        else { return nil }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            CaptureMode(rawValue: key).map { ($0, value) }
        })
    }

    // MARK: - Derived

    static var defaultSaveFolder: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
    }

    /// Short, friendly name for the save folder (e.g. "Desktop").
    var saveFolderDisplay: String {
        let name = (saveFolderPath as NSString).lastPathComponent
        return name.isEmpty ? saveFolderPath : name
    }

    // MARK: - Side effects

    /// Re-applies the saved appearance. Call once at launch (see AppDelegate).
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[PrtScn] launch-at-login change failed: \(error)")
        }
    }
}
