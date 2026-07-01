import AppKit
import SwiftUI

/// The editor's window body: the annotation canvas with a floating tool palette
/// over it. Copy / Save / Copy-Text live in the title-bar toolbar (see
/// `EditorController`); the keyboard shortcuts for everything live here, in the
/// content view's responder chain, so they fire wherever the buttons sit.
struct EditorView: View {
    @Bindable var model: EditorModel

    /// Which inline palette section is open. A single source of truth keeps the
    /// text and color expanders mutually exclusive.
    @State private var expanded: PaletteSection?

    private enum PaletteSection { case text, counter, measure, color }

    /// Opens `target` (or closes, if `nil`). When switching directly between two
    /// open sections, the current one collapses *before* the next expands, so
    /// the two animations never run in parallel.
    private func setExpanded(_ target: PaletteSection?) {
        guard expanded != target else { return }
        let animation = Animation.snappy(duration: 0.2)
        if expanded == nil || target == nil {
            withAnimation(animation) { expanded = target }
        } else {
            withAnimation(animation) { expanded = nil } completion: {
                withAnimation(animation) { expanded = target }
            }
        }
    }

    var body: some View {
        EditorCanvas(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Fixed dark backdrop (not theme-driven) so transparent window-shots
            // and any letterboxing read consistently regardless of appearance.
            .background(Color(white: 0.13))
            .overlay(alignment: .bottom) {
                if model.isCropping { cropBar } else { palette }
            }
            .overlay(alignment: .top) { toast }
            .background(shortcuts)
            .frame(minWidth: EditorController.minContentSize.width,
                   minHeight: EditorController.minContentSize.height)
            // Top-bar tools (pixelate) and crop mode collapse any open section.
            .onChange(of: model.tool) { _, tool in
                if tool == .pixelate, expanded != nil { setExpanded(nil) }
            }
            .onChange(of: model.isCropping) { _, cropping in
                if cropping, expanded != nil { setExpanded(nil) }
            }
    }

    // MARK: - Tool palette

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(EditTool.allCases.filter {
                $0 != .text && $0 != .pixelate && $0 != .counter && $0 != .measure
            }) { tool in
                PaletteButton(help: tool.label, isOn: model.tool == tool) {
                    model.tool = tool
                    setExpanded(nil)
                } icon: { tool.icon }
            }

            MeasureToolControl(model: model, isExpanded: expanded == .measure) {
                model.tool = .measure
                setExpanded(expanded == .measure ? nil : .measure)
            }

            TextToolControl(model: model, isExpanded: expanded == .text) {
                model.tool = .text
                setExpanded(expanded == .text ? nil : .text)
            }

            CounterToolControl(model: model, isExpanded: expanded == .counter) {
                model.tool = .counter
                setExpanded(expanded == .counter ? nil : .counter)
            }

            Divider().frame(height: 20)

            ColorPalette(selection: $model.color, isExpanded: expanded == .color,
                         onToggle: { setExpanded(expanded == .color ? nil : .color) },
                         collapse: { setExpanded(nil) })

            Divider().frame(height: 20)

            PaletteButton(help: "Undo (⌘Z)", disabled: !model.canUndo,
                          action: { model.undo() }) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 15, weight: .medium))
            }
            PaletteButton(help: "Redo (⇧⌘Z)", disabled: !model.canRedo,
                          action: { model.redo() }) {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 15, weight: .medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 16)
    }

    // MARK: - Crop bar

    private var cropBar: some View {
        HStack(spacing: 10) {
            Button("Cancel") { model.cancelCrop() }
                .buttonStyle(.bordered)
            Button("Crop") { model.applyCrop() }
                .buttonStyle(.borderedProminent)
                .disabled(model.cropRect == nil)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 16)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toast: some View {
        if model.isPickingColor {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.hoverColor ?? .clear)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: 14, height: 14)
                Text(model.hoverColorHex ?? "Hover the capture")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if let status = model.statusMessage {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Keyboard shortcuts

    private var shortcuts: some View {
        Group {
            Button("", action: model.copy).keyboardShortcut("c", modifiers: .command)
            Button("", action: model.save).keyboardShortcut("s", modifiers: .command)
            Button("", action: model.copyText).keyboardShortcut("t", modifiers: .command)
            Button("", action: model.undo).keyboardShortcut("z", modifiers: .command)
            Button("", action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift])
            Button("", action: model.deleteSelected).keyboardShortcut(.delete, modifiers: [])
            Button("", action: { if model.isCropping { model.applyCrop() } })
                .keyboardShortcut(.return, modifiers: [])
            Button("") {
                if model.isCropping { model.cancelCrop() }
                else if model.isPickingColor { model.cancelPickingColor() }
                else { model.selectedID = nil }
            }
            .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// A flat, square palette button with an active/hover/disabled state and a
/// custom icon view.
private struct PaletteButton<Icon: View>: View {
    let help: String
    var isOn = false
    var disabled = false
    let action: () -> Void
    let icon: Icon

    @State private var hovering = false

    init(help: String, isOn: Bool = false, disabled: Bool = false,
         action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.help = help
        self.isOn = isOn
        self.disabled = disabled
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: 32, height: 28)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var background: Color {
        if isOn { return .accentColor.opacity(0.9) }
        return hovering ? .primary.opacity(0.12) : .clear
    }
}

/// The text tool button which, while active, expands size (−/+) and typeface
/// (Aa in each design) controls to the right — mirroring the color control.
private struct TextToolControl: View {
    let model: EditorModel
    let isExpanded: Bool
    let onToggle: () -> Void

    /// Nested expansion: the three font options only appear while choosing, so
    /// the toolbar stays compact the rest of the time.
    @State private var fontExpanded = false

    var body: some View {
        HStack(spacing: 6) {
            // Toolbar button shows "Aa" in the current font; tapping selects the
            // text tool and toggles the controls.
            PaletteButton(help: EditTool.text.label, isOn: model.tool == .text, action: onToggle) {
                Text("Aa").font(.system(size: 14, weight: .semibold,
                                        design: model.fontDesign.swiftUIDesign))
            }

            if isExpanded {
                Divider().frame(height: 18)
                fontPicker
                Divider().frame(height: 18)
                SizeStepper(points: model.inPoints(model.fontSize)) { model.adjustFontSize(by: $0) }
                // Marks where this control's expansion ends, since whatever
                // sits next in the toolbar otherwise butts right up against it.
                Divider().frame(height: 18)
            }
        }
        .onChange(of: isExpanded) { _, open in if !open { fontExpanded = false } }
    }

    @ViewBuilder
    private var fontPicker: some View {
        if fontExpanded {
            ForEach(FontDesign.allCases) { design in
                PaletteButton(help: design.label, isOn: model.fontDesign == design) {
                    model.setFontDesign(design)
                    withAnimation(.snappy(duration: 0.2)) { fontExpanded = false }
                } icon: {
                    Text("Ff").font(.system(size: 14, weight: .semibold, design: design.swiftUIDesign))
                }
            }
        } else {
            PaletteButton(help: "Font: \(model.fontDesign.label)") {
                withAnimation(.snappy(duration: 0.2)) { fontExpanded = true }
            } icon: {
                Text("Ff").font(.system(size: 14, weight: .semibold, design: model.fontDesign.swiftUIDesign))
            }
        }
    }
}

/// The step-counter tool: a knockout next-number badge that, while active,
/// expands a size stepper.
private struct CounterToolControl: View {
    let model: EditorModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaletteButton(help: EditTool.counter.label, isOn: model.tool == .counter, action: onToggle) {
                ZStack {
                    // `.foreground` so it's black like the other icons (white when active).
                    Circle().fill(.foreground)
                    Text("\(model.nextCounter)")
                        .font(.system(size: 11, weight: .bold))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(width: 18, height: 18)
            }

            if isExpanded {
                Divider().frame(height: 18)
                SizeStepper(points: model.inPoints(model.counterSize)) { model.adjustCounterSize(by: $0) }
                // Marks where this control's expansion ends, since whatever
                // sits next in the toolbar otherwise butts right up against it.
                Divider().frame(height: 18)
            }
        }
    }
}

/// The measure tool: a dimension line with a pixel-count label that, while
/// active, expands a size stepper for that label — independent of the text
/// tool's own size.
private struct MeasureToolControl: View {
    let model: EditorModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaletteButton(help: EditTool.measure.label, isOn: model.tool == .measure, action: onToggle) {
                EditTool.measure.icon
            }

            if isExpanded {
                Divider().frame(height: 18)
                SizeStepper(points: model.inPoints(model.measureSize)) { model.adjustMeasureSize(by: $0) }
                // Marks where this control's expansion ends, since whatever
                // sits next in the toolbar otherwise butts right up against it.
                Divider().frame(height: 18)
            }
        }
    }
}

/// A `−  size  +` stepper bound to a given size value and adjuster.
private struct SizeStepper: View {
    let points: Int
    let adjust: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaletteButton(help: "Smaller", action: { adjust(1 / 1.15) }) {
                Image(systemName: "minus").font(.system(size: 13, weight: .semibold))
            }
            Text("\(points)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 30)
            PaletteButton(help: "Larger", action: { adjust(1.15) }) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

/// A compact color control: collapsed, it shows just the current color. Tapping
/// it expands a row of presets to the right (plus a rainbow well that opens the
/// macOS color picker); choosing any color collapses it back.
private struct ColorPalette: View {
    @Binding var selection: Color
    let isExpanded: Bool
    let onToggle: () -> Void
    let collapse: () -> Void

    @State private var panelProxy = ColorPanelProxy()

    private static let presets: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black,
    ]

    var body: some View {
        HStack(spacing: 4) {
            // The always-visible current color, which toggles the row.
            swatch(selection, selected: false, action: onToggle)
                .help("Color")

            if isExpanded {
                Divider().frame(height: 18)
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, color in
                    swatch(color, selected: color == selection) { choose(color) }
                }
                rainbowWell
            }
        }
        .padding(.horizontal, isExpanded ? 2 : 0)
    }

    private func swatch(_ color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    /// Rainbow well — opens the native macOS color picker, with live updates.
    private var rainbowWell: some View {
        Button {
            panelProxy.onChange = { selection = $0 }
            let panel = NSColorPanel.shared
            panel.color = NSColor(selection)
            panel.isContinuous = true
            panel.setTarget(panelProxy)
            panel.setAction(#selector(ColorPanelProxy.colorChanged(_:)))
            panel.orderFront(nil)
            collapse()
        } label: {
            Circle()
                .fill(AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                    center: .center))
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 14, height: 14)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Custom…")
        .transition(.scale.combined(with: .opacity))
    }

    private func choose(_ color: Color) {
        selection = color
        collapse()
    }
}

/// Bridges the shared `NSColorPanel`'s target/action back to a SwiftUI binding.
@MainActor
final class ColorPanelProxy: NSObject {
    var onChange: ((Color) -> Void)?

    @objc func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(sender.color))
    }
}
