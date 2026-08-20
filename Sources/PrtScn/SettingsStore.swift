import AppKit
import Carbon
import Observation
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "SettingsStore")

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

    /// Every preview-card action in display order; `hiddenPreviewActions`
    /// says which of them the card actually shows. Kept separate so a hidden
    /// action remembers its slot.
    var previewActionOrder: [PreviewAction] {
        didSet { defaults.set(previewActionOrder.map(\.rawValue), forKey: Keys.previewActionOrder) }
    }

    /// Actions without a button on the preview card. Their keyboard
    /// shortcuts keep working — hiding is visual decluttering only.
    var hiddenPreviewActions: Set<PreviewAction> {
        didSet { defaults.set(hiddenPreviewActions.map(\.rawValue), forKey: Keys.hiddenPreviewActions) }
    }

    /// The card never drops below this many visible actions.
    static let minVisiblePreviewActions = 3

    /// The actions the preview card shows, in order.
    var visiblePreviewActions: [PreviewAction] {
        previewActionOrder.filter { !hiddenPreviewActions.contains($0) }
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

    /// Last-used line tool end decorations (none / arrow / bar per endpoint).
    var editorLineStartCap: LineCap {
        didSet { defaults.set(editorLineStartCap.rawValue, forKey: Keys.editorLineStartCap) }
    }

    var editorLineEndCap: LineCap {
        didSet { defaults.set(editorLineEndCap.rawValue, forKey: Keys.editorLineEndCap) }
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

    /// The size presets offered in the fixed-size capture dialog, editable in
    /// Settings → Capture (up to `maxFixedSizePresets`).
    var fixedSizePresets: [FixedSizePreset] {
        didSet {
            if let data = try? JSONEncoder().encode(fixedSizePresets) {
                defaults.set(data, forKey: Keys.fixedSizePresets)
            }
        }
    }

    static let maxFixedSizePresets = 6

    /// Common frames: classic 4:3s, HD sizes, social square, and OG image.
    static let defaultFixedSizePresets: [FixedSizePreset] = [
        FixedSizePreset(width: 640, height: 480),
        FixedSizePreset(width: 800, height: 600),
        FixedSizePreset(width: 1280, height: 720),
        FixedSizePreset(width: 1920, height: 1080),
        FixedSizePreset(width: 1080, height: 1080),
        FixedSizePreset(width: 1200, height: 630),
    ]

    /// Height cap for scrolling captures, in pixels. Clamped below Metal's
    /// 16,384-px maximum texture size: anything taller is silently
    /// downsampled by the display pipeline (editor, Quick Look, Preview)
    /// and looks blurry at every zoom even though the file is sharp.
    /// Under `@Observable` this is a computed property, so a self-assignment
    /// inside `didSet` re-enters it (the plain-stored-property exemption
    /// doesn't apply) — only re-assign when clamping changes the value, and
    /// let that inner pass do the persisting.
    var scrollMaxHeight: Int {
        didSet {
            let clamped = Self.clampedScrollMaxHeight(scrollMaxHeight)
            if clamped != scrollMaxHeight {
                scrollMaxHeight = clamped
                return
            }
            defaults.set(scrollMaxHeight, forKey: Keys.scrollMaxHeight)
        }
    }

    static let defaultScrollMaxHeight = 15_000

    static func clampedScrollMaxHeight(_ value: Int) -> Int {
        min(max(value, 2_000), 16_000)
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
        static let previewActionOrder = "previewActionOrder"
        static let hiddenPreviewActions = "hiddenPreviewActions"
        static let saveFolder = "saveFolder"
        static let shortcuts = "shortcuts"
        static let windowBackground = "windowBackground"
        static let windowBackgroundColor = "windowBackgroundColor"
        static let closeEditorAfterAction = "closeEditorAfterAction"
        static let editorColor = "editorColor"
        static let editorFontDesign = "editorFontDesign"
        static let editorLineStartCap = "editorLineStartCap"
        static let editorLineEndCap = "editorLineEndCap"
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
        static let fixedSizePresets = "fixedSizePresets"
        static let scrollMaxHeight = "scrollMaxHeight"
        static let scrollingShortcutMigrated = "scrollingShortcutMigrated"
        static let fixedSizeShortcutMigrated = "fixedSizeShortcutMigrated"
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
        let actionOrder = Self.loadPreviewActionOrder(from: defaults)
        previewActionOrder = actionOrder
        hiddenPreviewActions = Self.loadHiddenPreviewActions(from: defaults, order: actionOrder)
        saveFolderPath = defaults.string(forKey: Keys.saveFolder) ?? Self.defaultSaveFolder
        windowBackground = WindowBackground(rawValue: defaults.string(forKey: Keys.windowBackground) ?? "") ?? .margins
        windowBackgroundColor = Color(hex: defaults.string(forKey: Keys.windowBackgroundColor) ?? Self.defaultWindowBackgroundColor)
        closeEditorAfterAction = defaults.object(forKey: Keys.closeEditorAfterAction) as? Bool ?? true
        editorColor = Color(hex: defaults.string(forKey: Keys.editorColor) ?? Self.defaultEditorColor)
        editorFontDesign = FontDesign(rawValue: defaults.string(forKey: Keys.editorFontDesign) ?? "") ?? .sans
        editorLineStartCap = LineCap(rawValue: defaults.string(forKey: Keys.editorLineStartCap) ?? "") ?? .none
        editorLineEndCap = LineCap(rawValue: defaults.string(forKey: Keys.editorLineEndCap) ?? "") ?? .arrow
        measureUnit = MeasureUnit(rawValue: defaults.string(forKey: Keys.measureUnit) ?? "") ?? .points
        measureLoupe = defaults.object(forKey: Keys.measureLoupe) as? Bool ?? true
        includePointer = defaults.object(forKey: Keys.includePointer) as? Bool ?? false
        shutterSound = defaults.object(forKey: Keys.shutterSound) as? Bool ?? true
        saveResolution = SaveResolution(rawValue: defaults.string(forKey: Keys.saveResolution) ?? "") ?? .native
        copyResolution = CopyResolution(rawValue: defaults.string(forKey: Keys.copyResolution) ?? "") ?? .native
        filenamePrefix = defaults.string(forKey: Keys.filenamePrefix) ?? "PrtScn"
        rememberLastTool = defaults.object(forKey: Keys.rememberLastTool) as? Bool ?? true
        // A remembered "arrow" from before the line/arrow merge falls back here.
        editorTool = EditTool(rawValue: defaults.string(forKey: Keys.editorTool) ?? "") ?? .line
        fixedSizeWidth = defaults.object(forKey: Keys.fixedSizeWidth) as? Int ?? 1280
        fixedSizeHeight = defaults.object(forKey: Keys.fixedSizeHeight) as? Int ?? 720
        fixedSizeUnit = FixedSizeUnit(rawValue: defaults.string(forKey: Keys.fixedSizeUnit) ?? "") ?? .pixels
        fixedSizePresets = Self.loadFixedSizePresets(from: defaults) ?? Self.defaultFixedSizePresets
        scrollMaxHeight = Self.clampedScrollMaxHeight(
            defaults.object(forKey: Keys.scrollMaxHeight) as? Int ?? Self.defaultScrollMaxHeight)
        shortcuts = Self.loadShortcuts(from: defaults) ?? Self.defaultShortcuts
        // Reflect the real system login-item state rather than a stored guess.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Shortcuts persisted before scrolling capture existed lack its
        // default hotkey — back-fill it exactly once, so users who later
        // clear it (Delete in the recorder) aren't fighting a resurrection
        // on every launch. `didSet` doesn't fire during init, so persist by
        // hand; hotkey registration happens at app startup regardless.
        if !defaults.bool(forKey: Keys.scrollingShortcutMigrated) {
            defaults.set(true, forKey: Keys.scrollingShortcutMigrated)
            if shortcuts[.scrolling] == nil, let shortcut = Self.defaultShortcuts[.scrolling] {
                shortcuts[.scrolling] = shortcut
                persistShortcuts()
            }
        }
        // Same back-fill for fixed-size capture (its ⌘⌥4-slot default likewise
        // postdates early installs). Skipped if the user meanwhile assigned
        // that combo to another mode — duplicates are rejected everywhere else.
        if !defaults.bool(forKey: Keys.fixedSizeShortcutMigrated) {
            defaults.set(true, forKey: Keys.fixedSizeShortcutMigrated)
            if shortcuts[.fixedSize] == nil, let shortcut = Self.defaultShortcuts[.fixedSize],
               !shortcuts.values.contains(shortcut) {
                shortcuts[.fixedSize] = shortcut
                persistShortcuts()
            }
        }
    }

    // MARK: - Shortcuts

    /// ⌘⌥1 / ⌘⌥2 / ⌘⌥3 / ⌘⌥4 (avoiding macOS's ⌘⇧3/4/5). The dev build — its
    /// own bundle id, run alongside the installed app — adds ⇧ so the two don't
    /// register the same global hotkeys. (Each variant persists its own
    /// shortcuts anyway; these are just the first-run defaults.)
    /// macOS's own screenshot combos (⇧⌘3 full screen, ⇧⌘4 area, ⇧⌘5 window,
    /// continuing the ladder for the app's extra modes). Offered as a one-click
    /// set for users who disable the system's Screenshots shortcuts — the
    /// system wins while they're still enabled, so registration would silently
    /// fail until then.
    static let systemShortcuts: [CaptureMode: Shortcut] = {
        let modifiers = UInt32(cmdKey | shiftKey)
        return [
            .fullScreen: Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers),
            .region: Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers),
            .window: Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: modifiers),
            .fixedSize: Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: modifiers),
            .scrolling: Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: modifiers),
        ]
    }()

    static let defaultShortcuts: [CaptureMode: Shortcut] = {
        let modifiers = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            ? UInt32(cmdKey | optionKey | shiftKey)
            : UInt32(cmdKey | optionKey)
        return [
            .region: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers),
            .window: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers),
            .fullScreen: Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers),
            .fixedSize: Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers),
            .scrolling: Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: modifiers),
        ]
    }()

    private func persistShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.shortcuts)
        }
    }

    /// Stored order merged with the current action set: unknown raw values
    /// are dropped, duplicates collapse, and actions added in later versions
    /// are appended — so they show up (visible) instead of never appearing
    /// for users with a saved layout.
    private static func loadPreviewActionOrder(from defaults: UserDefaults) -> [PreviewAction] {
        let stored = (defaults.stringArray(forKey: Keys.previewActionOrder) ?? [])
            .compactMap(PreviewAction.init(rawValue:))
        var seen = Set<PreviewAction>()
        var order = stored.filter { seen.insert($0).inserted }
        order.append(contentsOf: PreviewAction.allCases.filter { !seen.contains($0) })
        return order
    }

    /// Stored hidden set, clamped so at least `minVisiblePreviewActions`
    /// stay visible even if the defaults were tampered with.
    private static func loadHiddenPreviewActions(
        from defaults: UserDefaults, order: [PreviewAction]
    ) -> Set<PreviewAction> {
        var hidden = Set(
            (defaults.stringArray(forKey: Keys.hiddenPreviewActions) ?? [])
                .compactMap(PreviewAction.init(rawValue:)))
        for action in order where order.count - hidden.count < minVisiblePreviewActions {
            hidden.remove(action)
        }
        return hidden
    }

    private static func loadFixedSizePresets(from defaults: UserDefaults) -> [FixedSizePreset]? {
        guard let data = defaults.data(forKey: Keys.fixedSizePresets) else { return nil }
        return try? JSONDecoder().decode([FixedSizePreset].self, from: data)
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
            log.error("launch-at-login change failed: \(String(describing: error), privacy: .public)")
        }
    }
}
