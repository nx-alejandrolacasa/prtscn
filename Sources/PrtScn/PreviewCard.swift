import SwiftUI

/// The floating preview card: thumbnail + countdown bar + Edit/Copy/Save toolbar.
///
/// The surface is macOS 26 Liquid Glass (`.glassEffect`), which renders its own
/// specular edge highlight and contextual shadow — so the card draws no manual
/// stroke or drop shadow of its own.
struct PreviewCard: View {
    let model: PreviewModel

    private let cardWidth: CGFloat = 248
    /// Inner padding around the thumbnail; also the inset that makes the
    /// thumbnail's corners sit concentrically inside the card's corners.
    private let contentPadding: CGFloat = 8
    /// Transparent breathing room around the card so the glass shadow has space
    /// to render (the panel window itself is clear). Static so the controller
    /// can account for it when positioning the visible card near the cursor.
    static let shadowMargin: CGFloat = 18

    private let cardCornerRadius: CGFloat = 16

    /// Drives the cursor-anchored entrance (scale + fade up from the pointer).
    @State private var appeared = false

    /// True while the user is dragging the screenshot out of the card.
    @State private var isDragging = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    /// The thumbnail spans the full content width; its corners are smaller than
    /// the card's by the padding, so the two radii stay concentric.
    private var thumbnailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius - contentPadding, style: .continuous)
    }

    private var contentWidth: CGFloat { cardWidth - contentPadding * 2 }

    /// Thumbnail height derived from the capture's aspect ratio so the image
    /// fills the full width and the card height adapts. Clamped only to guard
    /// against extreme aspect ratios.
    private var thumbnailHeight: CGFloat {
        let size = model.image.size
        guard size.width > 0 else { return 140 }
        let proportional = contentWidth * size.height / size.width
        return min(max(proportional, 80), 220)
    }

    var body: some View {
        VStack(spacing: 0) {
            thumbnail
                .padding(contentPadding)
            if model.timeout > 0 {
                countdownBar
            }
            toolbar
        }
        .frame(width: cardWidth)
        .glassEffect(.regular, in: shape)
        .padding(Self.shadowMargin)
        .scaleEffect(appeared ? 1 : 0.92, anchor: .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .onHover { model.isHovering = $0 }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .task { await model.runCountdown() }
        .background(escapeHandler)
    }

    // MARK: - Thumbnail + hover hint

    private var thumbnail: some View {
        ZStack(alignment: .top) {
            Image(nsImage: model.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: contentWidth, height: thumbnailHeight)
                .clipped()
                .background(Color.black.opacity(0.04))
                .clipShape(thumbnailShape)
                .overlay(thumbnailShape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .overlay {
                    DraggableImage(image: model.image, fileURL: model.imageURL) { dragging in
                        withAnimation(.easeOut(duration: 0.15)) { isDragging = dragging }
                        // Keep the card alive (pause auto-dismiss) for the
                        // duration of the drag; release the pause when it ends.
                        model.isHovering = dragging
                    }
                    .clipShape(thumbnailShape)
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

    // MARK: - Countdown bar

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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(PreviewAction.allCases) { action in
                ToolbarButton(
                    action: action,
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, contentPadding)
        .padding(.bottom, contentPadding)
        .padding(.top, model.timeout > 0 ? 0 : contentPadding)
    }

    /// Invisible button that maps the Escape key to dismiss.
    private var escapeHandler: some View {
        Button("", action: { model.dismiss() })
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
    }
}

/// A single flat icon button in the preview toolbar. It's fully transparent so
/// the card's Liquid Glass shows straight through it (matching tone); only a
/// soft fill appears on hover, which also lights up the glass beneath.
private struct ToolbarButton: View {
    let action: PreviewAction
    let onHover: (Bool) -> Void
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 32)
                .background(
                    hovering ? Color.primary.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
