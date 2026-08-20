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

    private enum PaletteSection { case line, shapes, text, counter, measure, color }

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
        // The canvas spans the whole content area; the frame margins around the
        // fitted capture (and their reduction by a window shot's transparent
        // surround) live inside `CanvasFit`, so a zoomed image can grow out of
        // its framed rectangle and bleed edge-to-edge.
        EditorCanvas(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A Photoshop-style transparency checkerboard, so transparent
            // window-shots and any letterboxing read clearly. Adapts its grays
            // to light/dark mode.
            .background(CheckerboardBackground())
            .overlay(alignment: .bottom) {
                if model.isCropping { cropBar } else { palette }
            }
            .overlay(alignment: .top) { toast }
            .background(shortcuts)
            .frame(minWidth: EditorController.minContentSize.width,
                   minHeight: EditorController.minContentSize.height)
            // The open section always follows the active tool — a selected
            // tool's subtools stay in view (tools without any, like pixelate,
            // collapse the bar).
            .onChange(of: model.tool) { _, tool in setExpanded(section(for: tool)) }
            // The preselected tool's section starts open (set directly, so it
            // doesn't animate in), putting its options in view without a click.
            .onAppear { expanded = section(for: model.tool) }
    }

    /// The palette section belonging to a tool — always shown while that tool
    /// is active. `nil` for tools without subtools.
    private func section(for tool: EditTool) -> PaletteSection? {
        switch tool {
        case .line: .line
        case .rectangle, .roundedRect, .ellipse: .shapes
        case .text: .text
        case .counter: .counter
        case .measure: .measure
        default: nil
        }
    }

    // MARK: - Tool palette

    private var palette: some View {
        HStack(spacing: 6) {
            // Tool buttons only ever *open* their section (switching tools
            // swaps it via `onChange`); the explicit `setExpanded` here covers
            // re-opening it over the color expander without a tool change.
            LineToolControl(model: model, isExpanded: expanded == .line) {
                model.tool = .line
                setExpanded(.line)
            }

            ShapeToolControl(model: model, isExpanded: expanded == .shapes) {
                model.selectShape(model.lastShapeTool)
                setExpanded(.shapes)
            }

            MeasureToolControl(model: model, isExpanded: expanded == .measure) {
                model.tool = .measure
                setExpanded(.measure)
            }

            TextToolControl(model: model, isExpanded: expanded == .text) {
                model.tool = .text
                setExpanded(.text)
            }

            CounterToolControl(model: model, isExpanded: expanded == .counter) {
                model.tool = .counter
                setExpanded(.counter)
            }

            Divider().frame(height: 20)

            // Closing the color expander returns to the active tool's section
            // rather than collapsing to nothing.
            ColorPalette(selection: $model.color, isExpanded: expanded == .color,
                         onToggle: { setExpanded(expanded == .color ? section(for: model.tool) : .color) },
                         collapse: { setExpanded(section(for: model.tool)) })

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
        // Pinned to the sub-toolbar's height (32 + its vertical padding), so
        // the palette is the same size with any section open — or none.
        .frame(height: 36)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, EditorController.contentMargin)
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
        .padding(.bottom, EditorController.contentMargin)
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
        } else if let tip = model.tipMessage {
            Label(tip, systemImage: "hand.draw")
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
            Button("", action: model.duplicateSelected).keyboardShortcut("d", modifiers: .command)
            Button("", action: model.zoomIn).keyboardShortcut("+", modifiers: .command)
            // ⌘= zooms in too — on many layouts "+" needs Shift, "=" doesn't.
            Button("", action: model.zoomIn).keyboardShortcut("=", modifiers: .command)
            Button("", action: model.zoomOut).keyboardShortcut("-", modifiers: .command)
            Button("", action: model.resetZoom).keyboardShortcut("0", modifiers: .command)
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

/// The classic image-editor "transparency" checkerboard, drawn behind the
/// capture so transparent window-shots and letterboxing read clearly. Its two
/// grays follow the current appearance (light vs. dark).
private struct CheckerboardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Tile edge in points; each cell is one square of the pattern.
    private let tile: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let (base, alt) = colorScheme == .dark
                ? (Color(white: 0.17), Color(white: 0.13))
                : (Color(white: 1.0), Color(white: 0.90))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))

            let cols = Int((size.width / tile).rounded(.up))
            let rows = Int((size.height / tile).rounded(.up))
            var squares = Path()
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 1 {
                    squares.addRect(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile,
                                           width: tile, height: tile))
                }
            }
            context.fill(squares, with: .color(alt))
        }
    }
}

/// A capsule-shaped "sub toolbar": the single, subtly darker background that
/// groups a tool's expanded options inside the palette (its elements draw no
/// backgrounds of their own beyond hover/active states). Fixed-height, so the
/// palette is the same size whichever tool's options are open.
private struct SubToolbar<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .frame(height: 32)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            // The system's semantic fill for grouped controls — a properly
            // tuned gray in both appearances, unlike a hand-rolled opacity.
            .background(Color(nsColor: .systemFill), in: Capsule())
            .transition(.scale.combined(with: .opacity))
    }
}

/// A flat palette button with an active/hover/disabled state and a custom
/// icon view. Two active looks: the accent circle (main-bar tools), or —
/// `segmented` — a raised white pill for an exclusive choice sitting on a
/// `SubToolbar` track, like a segmented control's selected segment.
private struct PaletteButton<Icon: View>: View {
    let help: String
    var isOn = false
    var disabled = false
    var segmented = false
    let action: () -> Void
    let icon: Icon

    @State private var hovering = false

    init(help: String, isOn: Bool = false, disabled: Bool = false, segmented: Bool = false,
         action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.help = help
        self.isOn = isOn
        self.disabled = disabled
        self.segmented = segmented
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(isOn && !segmented ? Color.white : Color.primary)
                .frame(width: segmented ? 38 : 32, height: 32)
                .background { background }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var shape: AnyShape {
        segmented ? AnyShape(Capsule()) : AnyShape(Circle())
    }

    @ViewBuilder private var background: some View {
        if segmented, isOn {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        } else if isOn {
            Circle().fill(Color.accentColor.opacity(0.9))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.12))
        }
    }
}

/// The merged line/arrow tool: while active, it expands a Start and an End
/// dropdown that set each endpoint's decoration (none / arrow / bar) — for the
/// next line drawn and, in place, for a selected one. The tool button's icon
/// follows the caps, arrow being the default look.
private struct LineToolControl: View {
    let model: EditorModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaletteButton(help: hasArrow ? "Arrow" : "Line", isOn: model.tool == .line,
                          action: onToggle) {
                toolIcon
            }

            if isExpanded {
                // The two cap dropdowns with a dot between them, so together
                // they read as the editable ends of one line — no labels.
                SubToolbar(spacing: 4) {
                    capMenu("Start", atStart: true,
                            selection: Binding(get: { model.lineStartCap },
                                               set: { model.setLineStartCap($0) }))
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                    capMenu("End", atStart: false,
                            selection: Binding(get: { model.lineEndCap },
                                               set: { model.setLineEndCap($0) }))
                }
            }
        }
    }

    private var hasArrow: Bool {
        model.lineStartCap == .arrow || model.lineEndCap == .arrow
    }

    @ViewBuilder private var toolIcon: some View {
        if hasArrow {
            Image(systemName: "arrow.up.right").font(.system(size: 15, weight: .medium))
        } else if model.lineStartCap == .bar || model.lineEndCap == .bar {
            BarsLineIcon()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "line.diagonal").font(.system(size: 15, weight: .medium))
        }
    }

    /// The dropdown for one endpoint, showing its current cap glyph. A Picker
    /// inside a Menu, so the current cap gets the native checkmark.
    private func capMenu(_ title: String, atStart: Bool, selection: Binding<LineCap>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(LineCap.allCases) { cap in
                    Text(cap.label).tag(cap)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            LineCapIcon(cap: selection.wrappedValue, atStart: atStart)
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.primary)
                .frame(width: 13, height: 9)
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("\(title) cap: \(selection.wrappedValue.label)")
    }
}

/// The merged shape tool (rectangle / rounded rectangle / ellipse): one button
/// in the bar that, while active, expands the three shapes inline. The button
/// itself re-arms the last shape used.
private struct ShapeToolControl: View {
    let model: EditorModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaletteButton(help: "Shapes", isOn: model.tool.isShape, action: onToggle) {
                Image(systemName: "square.on.circle").font(.system(size: 15, weight: .medium))
            }

            if isExpanded {
                SubToolbar {
                    ForEach(EditTool.shapes) { shape in
                        PaletteButton(help: shape.label, isOn: model.tool == shape,
                                      segmented: true) {
                            model.selectShape(shape)
                        } icon: { shape.icon }
                    }
                }
            }
        }
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
                SubToolbar {
                    fontPicker
                    SizeStepper(points: model.inPoints(model.fontSize)) { model.adjustFontSize(by: $0) }
                }
            }
        }
        .onChange(of: isExpanded) { _, open in if !open { fontExpanded = false } }
    }

    @ViewBuilder
    private var fontPicker: some View {
        if fontExpanded {
            ForEach(FontDesign.allCases) { design in
                PaletteButton(help: design.label, isOn: model.fontDesign == design,
                              segmented: true) {
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
                SubToolbar {
                    SizeStepper(points: model.inPoints(model.counterSize)) { model.adjustCounterSize(by: $0) }
                }
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
                SubToolbar {
                    SizeStepper(points: model.inPoints(model.measureSize)) { model.adjustMeasureSize(by: $0) }
                }
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
                SubToolbar(spacing: 4) {
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, color in
                        swatch(color, selected: color == selection) { choose(color) }
                    }
                    rainbowWell
                }
            }
        }
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
