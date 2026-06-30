import SwiftUI

/// The floating preview card: thumbnail + countdown bar + Edit/Copy/Save toolbar.
struct PreviewCard: View {
    let model: PreviewModel

    private let cardWidth: CGFloat = 248
    /// Inner padding around the thumbnail; also the inset that makes the
    /// thumbnail's corners sit concentrically inside the card's corners.
    private let contentPadding: CGFloat = 8
    /// Transparent breathing room around the card so the drop shadow has space
    /// to render (the panel window itself is clear). Static so the controller
    /// can account for it when positioning the visible card near the cursor.
    static let shadowMargin: CGFloat = 18

    private let cardCornerRadius: CGFloat = 16

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
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .padding(Self.shadowMargin)
        .onHover { model.isHovering = $0 }
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

            if let action = model.hoveredAction {
                hintPill(action)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.hoveredAction)
    }

    private func hintPill(_ action: PreviewAction) -> some View {
        HStack(spacing: 6) {
            Text(action.label).fontWeight(.semibold)
            Text(action.shortcutHint).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    // MARK: - Countdown bar

    private var countdownBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * model.progress)
        }
        .frame(height: 2)
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
        .padding(.vertical, 6)
        .overlay(Divider(), alignment: .top)
    }

    /// Invisible button that maps the Escape key to dismiss.
    private var escapeHandler: some View {
        Button("", action: { model.dismiss() })
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
    }
}

/// A single flat icon button in the preview toolbar: no focus ring, subtle
/// hover highlight, crisp SF Symbol.
private struct ToolbarButton: View {
    let action: PreviewAction
    let onHover: (Bool) -> Void
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 30)
                .background(
                    hovering ? Color.primary.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(action.keyboardShortcut)
        .onHover { isHovering in
            hovering = isHovering
            onHover(isHovering)
        }
    }
}
