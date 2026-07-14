import AppKit
import SwiftUI

/// Whether the fixed-size dimensions mean output pixels or screen points.
/// They only differ on Retina displays: a 1280 px frame is 640 pt on screen,
/// while a 1280 pt frame saves as a 2560 px image.
enum FixedSizeUnit: String, CaseIterable, Identifiable, Codable {
    case pixels
    case points

    var id: Self { self }

    var label: String {
        switch self {
        case .pixels: "px"
        case .points: "pt"
        }
    }
}

/// The small "what size?" dialog shown before a fixed-size capture. On
/// Capture it hands the chosen size to `FixedSizeOverlay` and remembers it
/// for next time.
@MainActor
final class FixedSizePrompt: NSObject, NSWindowDelegate {
    static let shared = FixedSizePrompt()

    private var panel: NSPanel?

    private override init() {}

    func show() {
        close()

        let view = FixedSizePromptView(
            width: SettingsStore.shared.fixedSizeWidth,
            height: SettingsStore.shared.fixedSizeHeight,
            unit: SettingsStore.shared.fixedSizeUnit,
            onCapture: { [weak self] size, unit in
                SettingsStore.shared.fixedSizeWidth = Int(size.width)
                SettingsStore.shared.fixedSizeHeight = Int(size.height)
                SettingsStore.shared.fixedSizeUnit = unit
                self?.close()
                FixedSizeOverlay.shared.begin(size: size, unit: unit)
            },
            onCancel: { [weak self] in self?.close() }
        )

        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable]
        panel.title = "Fixed Size Capture"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        position(panel)
        self.panel = panel

        // Accessory app: activate first or the dialog opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// The title-bar close button — treat it as Cancel.
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }

    /// Slightly above center of the screen the cursor is on (where the
    /// capture is about to happen), not necessarily the main screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12
        ))
    }
}

/// Width × height entry with a px/pt unit toggle and a preset picker.
private struct FixedSizePromptView: View {
    @State private var width: Int
    @State private var height: Int
    @State private var unit: FixedSizeUnit
    @FocusState private var focused: Field?

    private enum Field { case width, height }

    let onCapture: (CGSize, FixedSizeUnit) -> Void
    let onCancel: () -> Void

    init(width: Int, height: Int, unit: FixedSizeUnit,
         onCapture: @escaping (CGSize, FixedSizeUnit) -> Void,
         onCancel: @escaping () -> Void) {
        _width = State(initialValue: width)
        _height = State(initialValue: height)
        _unit = State(initialValue: unit)
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    /// Common frames: classic 4:3s, HD sizes, social square, and OG image.
    private static let presets: [(width: Int, height: Int)] = [
        (640, 480), (800, 600), (1280, 720), (1920, 1080), (1080, 1080), (1200, 630),
    ]

    /// The preset matching the current fields, or -1 ("Custom"). Editing a
    /// field deselects the preset automatically; picking one fills the fields.
    private var presetSelection: Binding<Int> {
        Binding(
            get: { Self.presets.firstIndex { $0.width == width && $0.height == height } ?? -1 },
            set: { index in
                guard Self.presets.indices.contains(index) else { return }
                width = Self.presets[index].width
                height = Self.presets[index].height
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // The same grouped two-column form the Settings tabs use: labels
            // in the left column, values right-aligned in one inset card.
            Form {
                Section {
                    Picker("Preset", selection: presetSelection) {
                        Text("Custom").tag(-1)
                        Divider()
                        ForEach(Self.presets.indices, id: \.self) { index in
                            let preset = Self.presets[index]
                            // verbatim: locale-formatted interpolation would
                            // render "1.080 × 1.080" with grouping separators.
                            Text(verbatim: "\(preset.width) × \(preset.height)").tag(index)
                        }
                    }
                    .pickerStyle(.menu)

                    LabeledContent("Size") {
                        HStack(spacing: 6) {
                            sizeField("Width", value: $width, field: .width)
                            Text("×")
                                .foregroundStyle(.secondary)
                            sizeField("Height", value: $height, field: .height)
                        }
                    }

                    LabeledContent("Unit") {
                        Picker("Unit", selection: $unit) {
                            ForEach(FixedSizeUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                } footer: {
                    Text(unit == .pixels
                        ? "The saved image will be exactly this many pixels."
                        : "Size on screen — Retina displays save at 2×.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    Text("Capture").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(width < 1 || height < 1)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 330, height: 252)
        .onAppear { focused = .width }
    }

    private func submit() {
        guard width >= 1, height >= 1 else { return }
        onCapture(CGSize(width: min(width, 10_000), height: min(height, 10_000)), unit)
    }

    private func sizeField(_ label: String, value: Binding<Int>, field: Field) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            // Inside a Form the title would render as an inline label next to
            // the field ("Width" cramped beside the box) — the "Size" row
            // label covers it; keep the title for placeholder/accessibility.
            .labelsHidden()
            .multilineTextAlignment(.center)
            .frame(width: 66)
            .focused($focused, equals: field)
            .onSubmit(submit)
    }
}
