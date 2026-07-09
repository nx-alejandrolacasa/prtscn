import SwiftUI

/// The floating preview, drawn in whichever style is selected in
/// Settings → Capture → "Preview style" so the design directions can be
/// compared live. Every style shares the same model, actions, keyboard
/// shortcuts, countdown, and drag-out behavior — they only arrange the same
/// pieces differently.
///
/// This file holds the style dispatcher, the building blocks all styles share,
/// and the classic card; the experimental styles live in PreviewCardStyles.swift.
struct PreviewCard: View {
    let model: PreviewModel

    /// Transparent breathing room around the visible card so shadows (and the
    /// polaroid's tilt) have space to render — the panel window itself is
    /// clear. Must exceed the shadow's full blur tail (~2× radius + offset) or
    /// the panel edge clips it into a visible hard line. Static so the
    /// controller can account for it when positioning the card near the cursor.
    static let shadowMargin: CGFloat = 36

    var body: some View {
        Group {
            switch SettingsStore.shared.previewStyle {
            case .classic: ClassicPreviewCard(model: model)
            case .islands: IslandsPreviewCard(model: model)
            }
        }
        .padding(Self.shadowMargin)
        .onHover { model.isHovering = $0 }
        .task { await model.runCountdown() }
        .background(escapeHandler)
    }

    /// Invisible button that maps the Escape key to discard: an explicit
    /// "cancel this shot" that deletes the capture, unlike the auto-dismiss
    /// timeout, which still applies the configured default action.
    private var escapeHandler: some View {
        Button("", action: { model.perform(.discard) })
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
    }
}

/// Menu-style finishing for a glass surface: the NSMenu edge treatment — a
/// crisp dark outer hairline with a brighter highlight rim just inside it —
/// plus a soft contextual shadow to lift it off the background. Liquid Glass
/// renders its own specular edge, but over a plain white backdrop there's
/// nothing to refract and the surface melts into the page — this keeps the
/// boundary legible without fighting the material.
extension View {
    func glassCardEdge(in shape: some InsettableShape) -> some View {
        self
            .overlay(shape.inset(by: 0.5).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .overlay(shape.strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)   // contact
            .shadow(color: .black.opacity(0.10), radius: 14, y: 6)    // ambient
    }
}

// MARK: - Shared: thumbnail

/// The screenshot thumbnail every style builds on: the aspect-fitted image,
/// the drag-out overlay, and the hover-hint / drag-hint pills over its top edge.
struct PreviewThumbnail: View {
    let model: PreviewModel
    let width: CGFloat
    let cornerRadius: CGFloat
    /// Invoked on a plain click (no drag) on the screenshot.
    var onClick: (() -> Void)? = nil
    @Binding var isDragging: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Height derived from the capture's aspect ratio so the image fills the
    /// full width and the card height adapts. Clamped only to guard against
    /// extreme aspect ratios.
    static func height(for image: NSImage, width: CGFloat) -> CGFloat {
        let size = image.size
        guard size.width > 0 else { return 140 }
        return min(max(width * size.height / size.width, 80), 220)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Image(nsImage: model.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: Self.height(for: model.image, width: width))
                .clipped()
                .background(Color.black.opacity(0.04))
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .overlay {
                    DraggableImage(image: model.image, fileURL: model.imageURL,
                                   onClick: onClick) { dragging in
                        withAnimation(.easeOut(duration: 0.15)) { isDragging = dragging }
                        // Keep the card alive (pause auto-dismiss) for the
                        // duration of the drag; release the pause when it ends.
                        model.isHovering = dragging
                    }
                    .clipShape(shape)
                }
                // The screenshot visibly "lifts out" of the card while dragging.
                .scaleEffect(isDragging ? 0.96 : 1)
                .opacity(isDragging ? 0.5 : 1)

            if isDragging {
                dragHint
                    .padding(.top, 8)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let action = model.hoveredAction {
                hintPill(action)
                    .padding(.top, 8)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.hoveredAction)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }

    /// Pill shown over the thumbnail while a drag-out is in progress.
    private var dragHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app.fill")
            Text("Drop into any app").fontWeight(.semibold)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
    }

    private func hintPill(_ action: PreviewAction) -> some View {
        HStack(spacing: 6) {
            Text(action.label).fontWeight(.semibold)
            Text(action.shortcutHint).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Shared: toolbar

/// The row of action buttons; each style wraps it in its own chrome.
struct PreviewToolbar: View {
    let model: PreviewModel
    /// Circular button highlights, for capsule-shaped chrome.
    var circularButtons = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PreviewAction.allCases) { action in
                ToolbarButton(
                    action: action,
                    circular: circularButtons,
                    onHover: { hovering in
                        if hovering {
                            model.hoveredAction = action
                        } else if model.hoveredAction == action {
                            model.hoveredAction = nil
                        }
                    },
                    perform: { model.perform(action) }
                )
            }
        }
    }
}

/// A single flat icon button in the preview toolbar. It's fully transparent so
/// the surface beneath shows straight through it (matching tone); only a soft
/// fill appears on hover, which also lights up the glass beneath.
struct ToolbarButton: View {
    let action: PreviewAction
    /// Circle hover highlight (for capsule chrome) instead of a rounded rect.
    var circular = false
    let onHover: (Bool) -> Void
    let perform: () -> Void

    @State private var hovering = false

    private var highlightShape: AnyShape {
        circular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Discard turns red on hover to read as destructive; the rest stay
    /// subtler than full primary (dark gray on light glass, light gray on
    /// dark), regaining contrast on hover.
    private var iconStyle: AnyShapeStyle {
        if action == .discard && hovering {
            AnyShapeStyle(Color.red)
        } else {
            AnyShapeStyle(.primary.opacity(hovering ? 0.9 : 0.65))
        }
    }

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconStyle)
                .frame(width: circular ? 34 : 40, height: circular ? 34 : 32)
                .background(
                    hovering ? Color.primary.opacity(0.12) : .clear,
                    in: highlightShape
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(action.keyboardShortcut)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering }
            onHover(isHovering)
        }
    }
}

// MARK: - Classic card

/// The original Shottr-style card: thumbnail + countdown bar + toolbar fused
/// into one macOS 26 Liquid Glass slab (`.glassEffect` renders its own specular
/// edge highlight and contextual shadow — no manual stroke or drop shadow).
private struct ClassicPreviewCard: View {
    let model: PreviewModel

    private let cardWidth: CGFloat = 248
    /// Inner padding around the thumbnail; also the inset that makes the
    /// thumbnail's corners sit concentrically inside the card's corners.
    private let contentPadding: CGFloat = 8
    private let cardCornerRadius: CGFloat = 16

    /// Drives the cursor-anchored entrance (scale + fade up from the pointer).
    @State private var appeared = false
    @State private var isDragging = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewThumbnail(model: model,
                             width: cardWidth - contentPadding * 2,
                             cornerRadius: cardCornerRadius - contentPadding,
                             isDragging: $isDragging)
                .padding(contentPadding)
            if model.timeout > 0 {
                countdownBar
            }
            PreviewToolbar(model: model)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, contentPadding)
                .padding(.bottom, contentPadding)
                .padding(.top, model.timeout > 0 ? 0 : contentPadding)
        }
        .frame(width: cardWidth)
        .glassEffect(.regular, in: shape)
        .glassCardEdge(in: shape)
        .scaleEffect(appeared ? 1 : 0.92, anchor: .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    /// Inset, capsule-shaped track that sits inside the glass rather than
    /// spanning the surface as a hard seam.
    private var countdownBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.tertiary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * model.progress)
                }
        }
        .frame(height: 3)
        .padding(.horizontal, contentPadding)
        .padding(.bottom, 4)
    }
}
