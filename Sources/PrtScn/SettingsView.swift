import AppKit
import Carbon
import SwiftUI

/// The panes of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, capture, preview, editor, hotkeys, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .preview: "Preview"
        case .editor: "Editor"
        case .hotkeys: "Hotkeys"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera"
        case .preview: "photo.on.rectangle"
        case .editor: "pencil.and.outline"
        case .hotkeys: "keyboard"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .capture: .blue
        case .preview: .orange
        case .editor: .purple
        case .hotkeys: .green
        case .about: .teal
        }
    }
}

/// The sidebar column of the Settings window. Its background stays clear so
/// the AppKit sidebar material behind it (see SettingsWindowController)
/// shows through — that material is what runs to the top of the window,
/// under the traffic lights.
struct SettingsSidebar: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        List(SettingsPane.allCases, selection: $model.pane) { pane in
            SettingsPaneLabel(pane: pane)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// The detail column: the selected pane's form.
struct SettingsDetail: View {
    let model: SettingsWindowModel

    var body: some View {
        Group {
            switch model.pane {
            case .general: GeneralSettingsView()
            case .capture: CaptureSettingsView()
            case .preview: PreviewSettingsView()
            case .editor: EditorSettingsView()
            case .hotkeys: HotkeySettingsView()
            case .about: AboutSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A sidebar row in the System Settings style: the pane name next to a small
/// white symbol on a rounded colored tile.
private struct SettingsPaneLabel: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Startup") {
                Toggle("Launch PrtScn at login", isOn: $settings.launchAtLogin)
            }

            Section("Files") {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Text(settings.saveFolderDisplay)
                            .foregroundStyle(.secondary)
                            .help(settings.saveFolderPath)
                        Button("Choose…", action: chooseFolder)
                    }
                }

                TextField("Filename prefix", text: $settings.filenamePrefix, prompt: Text("PrtScn"))
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: settings.saveFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }
}

// MARK: - Capture

private struct CaptureSettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Window screenshots") {
                Picker("Background", selection: $settings.windowBackground) {
                    ForEach(WindowBackground.allCases) { background in
                        Text(background.label).tag(background)
                    }
                }
                if settings.windowBackground == .solidColor {
                    ColorPicker("Color", selection: $settings.windowBackgroundColor, supportsOpacity: false)
                }
            }

            Section {
                Picker("Save as", selection: $settings.saveResolution) {
                    ForEach(SaveResolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                Picker("Copy as", selection: $settings.copyResolution) {
                    ForEach(CopyResolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
            } header: {
                Text("Resolution")
            } footer: {
                Text("Applies to captures from HiDPI (Retina) displays. Both saves the downscaled file alongside the native one.")
            }

            FixedSizePresetsSection()

            Section {
                LabeledContent("Maximum height") {
                    HStack(spacing: 8) {
                        TextField("", value: $settings.scrollMaxHeight,
                                  format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("px")
                            .foregroundStyle(.secondary)
                        Button("Reset") {
                            settings.scrollMaxHeight = SettingsStore.defaultScrollMaxHeight
                        }
                        .disabled(settings.scrollMaxHeight == SettingsStore.defaultScrollMaxHeight)
                    }
                }
            } header: {
                Text("Scrolling screenshots")
            } footer: {
                Text("The capture stops once the stitched image reaches this height, in image pixels (a Retina capture packs 2 px per screen point). Capped at 16,000 px — macOS can't display taller images at full resolution.")
            }

            Section("Options") {
                Toggle("Include the mouse pointer (full-screen captures)",
                       isOn: $settings.includePointer)
                Toggle("Play the shutter sound", isOn: $settings.shutterSound)
            }
        }
        .formStyle(.grouped)
    }
}

/// The editable preset list for fixed-size capture: one row per preset with a
/// remove button (drag to reorder), plus a width × height entry row to add
/// new ones.
private struct FixedSizePresetsSection: View {
    @Bindable var settings = SettingsStore.shared
    @State private var newWidth: Int?
    @State private var newHeight: Int?
    @FocusState private var focusedField: Field?
    @State private var draggedPreset: FixedSizePreset?
    @State private var tabKeyMonitor: Any?

    private enum Field { case width, height }

    private var atCapacity: Bool {
        settings.fixedSizePresets.count >= SettingsStore.maxFixedSizePresets
    }

    /// The preset the entry fields describe, once both are valid.
    private var newPreset: FixedSizePreset? {
        guard let width = newWidth, let height = newHeight,
              width >= 1, height >= 1 else { return nil }
        return FixedSizePreset(width: min(width, 10_000), height: min(height, 10_000))
    }

    private var canAdd: Bool {
        guard let preset = newPreset else { return false }
        return !atCapacity && !settings.fixedSizePresets.contains(preset)
    }

    var body: some View {
        Section {
            ForEach(settings.fixedSizePresets) { preset in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    Text(preset.label)

                    Spacer()

                    Button {
                        settings.fixedSizePresets.removeAll { $0 == preset }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove preset")
                    .accessibilityLabel("Remove \(preset.width) by \(preset.height) preset")
                }
                .accessibilityElement(children: .combine)
                // The whole row is the drag surface — without an explicit
                // content shape only the rendered text/icons would start a
                // drag, not the empty space between them.
                .contentShape(Rectangle())
                .onDrag {
                    draggedPreset = preset
                    return NSItemProvider(object: preset.id as NSString)
                }
                .onDrop(of: [.text],
                        delegate: PresetReorderDelegate(item: preset, dragged: $draggedPreset))
            }

            if !atCapacity {
                LabeledContent("Add preset") {
                    HStack(spacing: 6) {
                        presetField("Width", value: $newWidth, field: .width)
                        Text("×")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        presetField("Height", value: $newHeight, field: .height)

                        Button(action: add) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canAdd)
                        .help("Add preset")
                        .accessibilityLabel("Add preset")
                    }
                }
            }
        } header: {
            Text("Fixed-size capture")
        } footer: {
            Text("Presets offered in the Capture Fixed Size dialog, up to \(SettingsStore.maxFixedSizePresets). Drag to reorder.")
        }
        // Tab between the width/height fields by hand: text fields in
        // grouped-form rows aren't in the window's key-view loop, so AppKit's
        // insertTab: (what Tab normally triggers) goes nowhere. Intercept the
        // key while one of our fields is focused and flip the FocusState —
        // programmatic focus does work. Only Tab presses with one of the two
        // fields focused are consumed; everything else passes through.
        .onAppear {
            // onAppear can re-fire without a matching onDisappear (container
            // transitions) — don't stack a second monitor over the first.
            guard tabKeyMonitor == nil else { return }
            tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == kVK_Tab else { return event }
                let handled = MainActor.assumeIsolated {
                    guard let current = focusedField else { return false }
                    // With exactly two fields, Tab and Shift-Tab both flip to
                    // the other one.
                    focusedField = current == .width ? .height : .width
                    return true
                }
                return handled ? nil : event
            }
        }
        .onDisappear {
            if let tabKeyMonitor {
                NSEvent.removeMonitor(tabKeyMonitor)
            }
            tabKeyMonitor = nil
        }
    }

    private func add() {
        guard let preset = newPreset, canAdd else { return }
        settings.fixedSizePresets.append(preset)
        newWidth = nil
        newHeight = nil
        focusedField = .width
    }


    /// `.focused` registers the fields with the focus system explicitly —
    /// without it, Tab doesn't traverse text fields inside grouped-form rows
    /// (same pattern as FixedSizePromptView's fields, where Tab works).
    private func presetField(_ label: String, value: Binding<Int?>, field: Field) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.center)
            .frame(width: 56)
            .focused($focusedField, equals: field)
            .onSubmit(add)
    }
}

/// Reorders presets live while dragging: entering a row slides the dragged
/// preset into that slot, and the drop just finalizes. `DropDelegate` (vs
/// `.dropDestination`) is what lets the proposal be `.move` — otherwise the
/// cursor shows the green "+" copy badge.
private struct PresetReorderDelegate: DropDelegate {
    let item: FixedSizePreset
    @Binding var dragged: FixedSizePreset?

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragged != nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragged, dragged != item else { return }
            let settings = SettingsStore.shared
            guard let from = settings.fixedSizePresets.firstIndex(of: dragged),
                  let to = settings.fixedSizePresets.firstIndex(of: item)
            else { return }
            withAnimation {
                settings.fixedSizePresets.move(
                    fromOffsets: IndexSet(integer: from),
                    toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragged = nil }
        return true
    }
}

// MARK: - Preview

private struct PreviewSettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Style") {
                Picker("Preview style", selection: $settings.previewStyle) {
                    ForEach(PreviewStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }

            Section("Dismissal") {
                Picker("Auto-dismiss after", selection: $settings.previewTimeout) {
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("Never").tag(0.0)
                }

                Picker("If dismissed without action", selection: $settings.defaultAction) {
                    ForEach(DefaultAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editor

private struct EditorSettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Tools") {
                Toggle("Reopen with the last-used tool", isOn: $settings.rememberLastTool)
            }
            Section("After an action") {
                Toggle("Close the editor after Copy, Save, or OCR",
                       isOn: $settings.closeEditorAfterAction)
            }
            Section("Measure tool") {
                Picker("Show distances in", selection: $settings.measureUnit) {
                    ForEach(MeasureUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Toggle("Show a magnifier loupe while measuring", isOn: $settings.measureLoupe)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkeys

private struct HotkeySettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Capture shortcuts") {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    shortcutRow(mode)
                }
            }

            Section {
                HStack(spacing: 12) {
                    Button("Restore Defaults") {
                        settings.shortcuts = SettingsStore.defaultShortcuts
                    }
                    Button("Use System Shortcuts") {
                        settings.shortcuts = SettingsStore.systemShortcuts
                    }
                    .help("⇧⌘3 full screen, ⇧⌘4 area, ⇧⌘5 window, ⇧⌘6 fixed size, ⇧⌘7 scrolling")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("""
                    “Use System Shortcuts” takes over macOS's own screenshot combos \
                    (⇧⌘3, ⇧⌘4, …). Disable the built-in ones first under \
                    System Settings → Keyboard → Keyboard Shortcuts → Screenshots, \
                    or the system keeps them.
                    """)
                    Button("Open Keyboard Settings…") {
                        // Deep link to the Keyboard pane; the Shortcuts sheet
                        // itself has no public anchor on modern macOS.
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ mode: CaptureMode) -> some View {
        LabeledContent(mode.title) {
            HStack(spacing: 8) {
                ShortcutRecorder(shortcut: settings.shortcuts[mode]) { newValue in
                    setShortcut(newValue, for: mode)
                }
                .frame(width: 130, height: 24)

                Button {
                    setShortcut(nil, for: mode)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(settings.shortcuts[mode] == nil ? 0 : 1)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(mode.title) shortcut")
                // Invisible (opacity 0) still hit-tests and lands in the
                // accessibility tree — hide it from both when cleared.
                .allowsHitTesting(settings.shortcuts[mode] != nil)
                .accessibilityHidden(settings.shortcuts[mode] == nil)
            }
        }
    }

    private func setShortcut(_ value: Shortcut?, for mode: CaptureMode) {
        // Reject a combo already assigned to another capture mode — the old
        // value stays, and the beep mirrors the recorder's modifier-less
        // rejection. (Registering the same combo twice would silently fail.)
        if let value, settings.shortcuts.contains(where: { $0.key != mode && $0.value == value }) {
            NSSound.beep()
            return
        }
        var updated = settings.shortcuts
        updated[mode] = value
        settings.shortcuts = updated
    }
}

// MARK: - About

/// The stand-in for the standard About panel (a menu-bar app has no app menu):
/// icon, name, version, author, and copyright, all read from the bundle so the
/// dev variant shows its own identity automatically.
private struct AboutSettingsView: View {
    private let updater = UpdateChecker.shared

    /// True for the dev variant, which opens the release page instead of
    /// self-installing — mirror that in the button label.
    private var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "PrtScn"
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Alejandro G. Lacasa"
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)

            Text(appName)
                .font(.title3.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)

            updateControls
                .padding(.top, 8)

            Text("The Print Screen key your Mac never had.")
                .font(.callout)
                .padding(.top, 10)

            Spacer(minLength: 0)

            Text("Created by Alejandro G. Lacasa")
                .font(.callout)
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    /// One line of update state under the version: a check button, progress,
    /// the install offer, or an error with retry.
    @ViewBuilder
    private var updateControls: some View {
        switch updater.phase {
        case .idle:
            Button("Check for Updates…") { Task { await updater.check() } }
                .controlSize(.small)
        case .checking:
            progressLine("Checking…")
        case .upToDate:
            Text("You're up to date.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available:
            HStack(spacing: 8) {
                Text("Version \(updater.latest?.version ?? "?") is available.")
                    .font(.caption)
                Button(isDevBuild ? "View on GitHub…" : "Install Update") {
                    Task { await updater.installLatest() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        case .downloading:
            progressLine("Downloading update…")
        case .installing:
            progressLine("Installing… the app will relaunch.")
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await updater.check() } }
                    .controlSize(.small)
            }
        }
    }

    private func progressLine(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
