import AppKit
import SwiftUI

/// The Settings window: General / Capture / Editor / Hotkeys / About tabs.
/// About lives here because a menu-bar app has no app menu to hang the
/// standard About panel from.
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

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
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
            Section("Preview") {
                Picker("Preview style", selection: $settings.previewStyle) {
                    ForEach(PreviewStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

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
