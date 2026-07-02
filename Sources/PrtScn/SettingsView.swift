import AppKit
import SwiftUI

/// The Settings window: General / Capture / Hotkeys tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            CaptureSettingsView()
                .tabItem { Label("Capture", systemImage: "camera") }

            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "pencil.and.outline") }

            HotkeySettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 320)
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Capture

private struct CaptureSettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Preview") {
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

            Section("Save location") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(settings.saveFolderDisplay)
                            .foregroundStyle(.secondary)
                            .help(settings.saveFolderPath)
                        Button("Choose…", action: chooseFolder)
                    }
                }
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

// MARK: - Editor

private struct EditorSettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("After an action") {
                Toggle("Close the editor after Copy, Save, or Copy Text",
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
                Button("Restore Defaults") {
                    settings.shortcuts = SettingsStore.defaultShortcuts
                }
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
            }
        }
    }

    private func setShortcut(_ value: Shortcut?, for mode: CaptureMode) {
        var updated = settings.shortcuts
        updated[mode] = value
        settings.shortcuts = updated
    }
}
