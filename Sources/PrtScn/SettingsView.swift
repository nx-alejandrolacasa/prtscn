import AppKit
import Carbon
import SwiftUI

/// The panes of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, capture, preview, editor, hotkeys, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .capture: String(localized: "Capture")
        case .preview: String(localized: "Preview")
        case .editor: String(localized: "Editor")
        case .hotkeys: String(localized: "Hotkeys")
        case .about: String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .capture: "camera.fill"
        case .preview: "photo.fill.on.rectangle.fill"
        case .editor: "pencil.and.outline"
        case .hotkeys: "keyboard.fill"
        case .about: "info"
        }
    }

    /// The labels of every setting the pane contains, for the sidebar search
    /// field. Reuses the forms' own localized keys so a Spanish user can
    /// search in Spanish. Keep in step when adding a control to a pane.
    var searchTerms: [String] {
        switch self {
        case .general: [
            "Appearance", "Theme", "Startup", "Launch PrtScn at login",
            "Dock", "Show Dock icon", "Files", "Save to", "Choose…", "Filename prefix",
        ].map { String(localized: String.LocalizationValue($0)) }
        case .capture: [
            "Window screenshots", "Background", "Color", "Resolution", "Save as",
            "Copy as", "Scrolling screenshots", "Maximum height", "Options",
            "Include the mouse pointer (full-screen captures)", "Play the shutter sound",
            "Fixed-size capture", "Add preset",
        ].map { String(localized: String.LocalizationValue($0)) }
        case .preview: [
            "Style", "Preview style", "Actions", "Dismissal", "Auto-dismiss after",
            "If dismissed without action",
        ].map { String(localized: String.LocalizationValue($0)) } + PreviewAction.allCases.map(\.label)
        case .editor: [
            "Tools", "Reopen with the last-used tool", "After an action",
            "Close the editor after Copy, Export, or OCR", "Measure tool",
            "Show distances in", "Show a magnifier loupe while measuring",
            "Blank canvas", "Size",
        ].map { String(localized: String.LocalizationValue($0)) }
        case .hotkeys:
            [String(localized: "Capture shortcuts"), String(localized: "Restore Defaults"),
             String(localized: "Use System Shortcuts")] + CaptureMode.allCases.map(\.title)
        case .about:
            [String(localized: "Check for Updates…"), String(localized: "View on GitHub…")]
        }
    }

    /// The setting labels matching `query` (case- and diacritic-insensitive),
    /// or `nil` when nothing in the pane — including its name — matches.
    /// An empty array means the pane name itself matched.
    func matches(_ query: String) -> [String]? {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || title.localizedStandardContains(query) { return [] }
        let hits = searchTerms.filter { $0.localizedStandardContains(query) }
        return hits.isEmpty ? nil : hits
    }

    var tint: Color {
        switch self {
        case .general: Color(red: 0.55, green: 0.55, blue: 0.57)
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

    /// Panes that survive the search, each with the setting labels that
    /// matched (empty when the pane name matched, so no subtitle is needed).
    private var results: [(pane: SettingsPane, hits: [String])] {
        SettingsPane.allCases.compactMap { pane in
            pane.matches(model.query).map { (pane, $0) }
        }
    }

    var body: some View {
        // Not a `List`. The sidebar list style insets its content by the
        // title bar it sits under, and re-evaluates that inset when the
        // window becomes key — so anything placed above or inside it (a
        // search field) saw the rows jump. `.searchable(placement: .sidebar)`
        // would have owned that inset properly, but it only materialises in
        // a `NavigationSplitView`, which can't give us the AppKit full-height
        // sidebar this window is built on. So the rows are drawn by hand in
        // a scroll view: every point of geometry here is ours and fixed.
        VStack(spacing: 0) {
            SettingsSearchField(text: $model.query)
                .padding(.horizontal, 12)
                .padding(.top, Self.fieldTop)
                .padding(.bottom, 12)

            let results = results
            if results.isEmpty {
                Text("No Results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results, id: \.pane) { result in
                            SettingsPaneRow(
                                pane: result.pane, hits: result.hits,
                                selected: model.pane == result.pane
                            ) { model.pane = result.pane }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Distance from the window's top edge to the search field: clears the
    /// traffic lights, which sit at the same height as the detail column's
    /// header capsule.
    private static let fieldTop: CGFloat = 46
}

/// One sidebar row, styled like the `.sidebar` list's: a rounded accent
/// highlight when selected (grey while the window is inactive, as AppKit
/// does), otherwise plain.
private struct SettingsPaneRow: View {
    let pane: SettingsPane
    let hits: [String]
    let selected: Bool
    let select: () -> Void

    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: select) {
            SettingsPaneLabel(pane: pane, hits: hits)
                .foregroundStyle(selected && activeState != .inactive ? .white : .primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(activeState == .inactive
                                  ? AnyShapeStyle(.primary.opacity(0.12))
                                  : AnyShapeStyle(.tint))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sidebar's search field, in System Settings' shape: a Liquid Glass
/// capsule with a leading magnifier and a clear button once there's text.
private struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search"), text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear"))
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onExitCommand { text = "" }
    }
}

/// The toolbar's contents for the detail side: history chevrons, then the pane
/// name a fixed gap away. Hosted as a single `NSToolbarItem` so AppKit places
/// it in the title bar next to the traffic lights, System Settings style.
struct SettingsPaneHeader: View {
    let model: SettingsWindowModel

    /// Fixed header width, leading-aligned: the toolbar item is sized to its
    /// content, so letting it shrink with the pane name ("About" vs "Hotkeys")
    /// slid the chevrons sideways on every selection.
    private static let width: CGFloat = 240

    var body: some View {
        HStack(spacing: 10) {
            historyChevrons

            Text(model.pane.title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)
        }
        .frame(width: Self.width, alignment: .leading)
    }

    /// One glass capsule split by a hairline, as in System Settings: back on
    /// the left, forward on the right, each dimmed when there's nowhere to go.
    /// The halves are near-square so the capsule reads as round, not as a flat
    /// pill.
    private var historyChevrons: some View {
        HStack(spacing: 0) {
            chevron("chevron.left", help: String(localized: "Back"), enabled: model.canGoBack) { model.goBack() }
            Divider().frame(height: 16).opacity(0.5)
            chevron("chevron.right", help: String(localized: "Forward"), enabled: model.canGoForward) { model.goForward() }
        }
        .glassEffect(.regular, in: Capsule())
    }

    private func chevron(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 31, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
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
///
/// The tile mirrors System Settings' own: 20 pt, continuous corners, a
/// top-lit gradient of the tint with a hairline highlight along the inside
/// edge and a faint drop shadow so it sits on the sidebar material rather
/// than floating flat. The symbol is pinned to 11 pt — the sidebar list
/// style otherwise applies `.imageScale(.large)` to label icons, which is
/// what made the glyphs overflow their tiles.
private struct SettingsPaneLabel: View {
    let pane: SettingsPane
    /// Setting labels that matched the search; shown under the pane name
    /// so the user sees *why* the pane is still listed.
    var hits: [String] = []

    private static let tileSize: CGFloat = 20
    private static let cornerRadius: CGFloat = 5.5

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                if !hits.isEmpty {
                    Text(hits.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            tile
        }
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return Image(systemName: pane.icon)
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .background(
                LinearGradient(
                    colors: [
                        pane.tint.mix(with: .white, by: 0.18),
                        pane.tint.mix(with: .black, by: 0.12),
                    ],
                    startPoint: .top, endPoint: .bottom),
                in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 0.75, y: 0.5)
            .accessibilityHidden(true)
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

            Section {
                Picker("Show Dock icon", selection: $settings.dockIcon) {
                    ForEach(DockIconMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Dock")
            } footer: {
                Text("The Dock icon is also what makes PrtScn reachable with ⌘Tab. While Editing shows it only while the editor window is open.")
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
        panel.prompt = String(localized: "Choose")
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
    @State private var draggedPreset: RowDrag<FixedSizePreset>?
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
                    draggedPreset = RowDrag(item: preset)
                    return NSItemProvider(object: preset.id as NSString)
                }
                .onDrop(of: [.text],
                        delegate: ReorderDelegate(item: preset, dragged: $draggedPreset) { dragged, target in
                            withAnimation {
                                SettingsStore.shared.fixedSizePresets.slide(dragged, to: target)
                            }
                        })
            }

            if !atCapacity {
                LabeledContent("Add preset") {
                    HStack(spacing: 6) {
                        presetField(String(localized: "Width"), value: $newWidth, field: .width)
                        Text("×")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        presetField(String(localized: "Height"), value: $newHeight, field: .height)

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

/// Reorders a settings list live while dragging (fixed-size presets, preview
/// actions): entering a row slides the dragged item into that slot, and the
/// drop just finalizes. `DropDelegate` (vs `.dropDestination`) is what lets
/// the proposal be `.move` — otherwise the cursor shows the green "+" copy
/// badge.
private struct ReorderDelegate<Item: Equatable>: DropDelegate {
    let item: Item
    @Binding var dragged: RowDrag<Item>?
    /// Slides the dragged item into the target's slot in the backing array.
    let move: @MainActor (_ dragged: Item, _ target: Item) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { currentDraggedItem() != nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragged = currentDraggedItem(), dragged != item else { return }
            move(dragged, item)
        }
    }

    /// The dragged row, if the drag in flight is still the one that picked
    /// it up. A cancelled drag never reaches `performDrop`, so its row would
    /// otherwise linger and let any later text drag reorder the list.
    @MainActor private func currentDraggedItem() -> Item? {
        guard var drag = dragged else { return nil }
        let changeCount = NSPasteboard(name: .drag).changeCount
        if drag.dragPasteboardChangeCount == nil {
            drag.dragPasteboardChangeCount = changeCount
            dragged = drag
        }
        guard drag.dragPasteboardChangeCount == changeCount else {
            dragged = nil
            return nil
        }
        return drag.item
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragged = nil }
        return true
    }
}

/// A row picked up for reordering, tied to its drag session by the drag
/// pasteboard's change count (every new drag, from any app, bumps it) —
/// pinned the first time the drag reaches a row.
private struct RowDrag<Item> {
    let item: Item
    var dragPasteboardChangeCount: Int?
}

extension Array where Element: Equatable {
    /// Slides `dragged` into `target`'s slot (`ReorderDelegate` move handler).
    mutating func slide(_ dragged: Element, to target: Element) {
        guard let from = firstIndex(of: dragged),
              let to = firstIndex(of: target) else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}

// MARK: - Preview

private struct PreviewSettingsView: View {
    @Bindable var settings = SettingsStore.shared
    @State private var draggedAction: RowDrag<PreviewAction>?

    var body: some View {
        Form {
            Section("Style") {
                Picker("Preview style", selection: $settings.previewStyle) {
                    ForEach(PreviewStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }

            Section {
                ForEach(settings.previewActionOrder) { action in
                    actionRow(action)
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("The buttons on the preview card. Drag to reorder; at least \(SettingsStore.minVisiblePreviewActions) stay visible. Hidden actions keep their keyboard shortcuts.")
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

    /// One preview action: grip + icon + label + shortcut, and an eye that
    /// shows/hides it on the card. Hidden rows dim but keep their slot, so
    /// re-showing restores the same position. The eye disables once hiding
    /// would drop the card below the visible minimum.
    private func actionRow(_ action: PreviewAction) -> some View {
        let hidden = settings.hiddenPreviewActions.contains(action)
        let atFloor = settings.visiblePreviewActions.count <= SettingsStore.minVisiblePreviewActions

        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Label {
                Text(action.label)
            } icon: {
                Image(systemName: action.systemImage)
            }
            .opacity(hidden ? 0.4 : 1)

            Spacer()

            Text(action.shortcutHint)
                .foregroundStyle(.secondary)
                .opacity(hidden ? 0.4 : 1)

            Button {
                if hidden {
                    settings.hiddenPreviewActions.remove(action)
                } else {
                    settings.hiddenPreviewActions.insert(action)
                }
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!hidden && atFloor)
            .help(hidden ? String(localized: "Show on the preview card") : String(localized: "Hide from the preview card"))
            .accessibilityLabel(hidden ? String(localized: "Show \(action.label)") : String(localized: "Hide \(action.label)"))
        }
        .accessibilityElement(children: .combine)
        // The whole row is the drag surface — without an explicit content
        // shape only the rendered text/icons would start a drag.
        .contentShape(Rectangle())
        .onDrag {
            draggedAction = RowDrag(item: action)
            return NSItemProvider(object: action.rawValue as NSString)
        }
        .onDrop(of: [.text],
                delegate: ReorderDelegate(item: action, dragged: $draggedAction) { dragged, target in
                    withAnimation {
                        SettingsStore.shared.previewActionOrder.slide(dragged, to: target)
                    }
                })
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
                Toggle("Close the editor after Copy, Export, or OCR",
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
            Section {
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        canvasField(String(localized: "Width"), value: $settings.canvasWidth)
                        Text("×")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        canvasField(String(localized: "Height"), value: $settings.canvasHeight)
                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Blank canvas")
            } footer: {
                Text("The size of the white image New Blank Canvas opens in the editor.")
            }
        }
        .formStyle(.grouped)
    }

    private func canvasField(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.center)
            .frame(width: 64)
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
        return String(localized: "Version \(short) (\(build))")
    }

    private var copyright: String {
        (Bundle.main.localizedInfoDictionary?["NSHumanReadableCopyright"]
            ?? Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright")) as? String
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
            progressLine(String(localized: "Checking…"))
        case .upToDate:
            HStack(spacing: 8) {
                Text("You're up to date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                cooldownButton(String(localized: "Check for Updates…"))
            }
        case .available:
            HStack(spacing: 8) {
                Text("Version \(updater.latest?.version ?? "?") is available.")
                    .font(.caption)
                Button(isDevBuild ? String(localized: "View on GitHub…") : String(localized: "Install Update")) {
                    Task { await updater.installLatest() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        case .downloading:
            progressLine(String(localized: "Downloading update…"))
        case .installing:
            progressLine(String(localized: "Installing… the app will relaunch."))
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                cooldownButton(String(localized: "Try Again"))
            }
        }
    }

    /// A re-check button that, while the cooldown runs, is disabled and shows
    /// the seconds left in place of its label.
    private func cooldownButton(_ label: String) -> some View {
        let remaining = updater.cooldownRemaining
        return Button(remaining > 0 ? String(localized: "\(remaining) s") : label) {
            Task { await updater.check() }
        }
        .controlSize(.small)
        .disabled(remaining > 0)
        .monospacedDigit()
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
