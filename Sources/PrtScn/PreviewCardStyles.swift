import SwiftUI

// The alternative preview styles (see PreviewStyle / Settings → Capture →
// "Preview style"). Composes the shared pieces from PreviewCard.swift —
// PreviewThumbnail, PreviewToolbar — into a different arrangement.
//
// Islands shows no countdown; auto-dismiss still runs, invisibly. (Only the
// classic card draws a countdown bar.)

// MARK: - Floating islands

/// The classic card de-fused: the thumbnail and the toolbar are each their own
/// glass island, floating in loose formation. The toolbar island is a capsule,
/// so its buttons use circular highlights, inset concentrically with the caps.
struct IslandsPreviewCard: View {
    let model: PreviewModel

    private let thumbnailWidth: CGFloat = 232
    private let framePadding: CGFloat = 7

    @State private var appeared = false
    @State private var isDragging = false

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                PreviewThumbnail(model: model, width: thumbnailWidth, cornerRadius: 10,
                                 onClick: { model.perform(.edit) },
                                 isDragging: $isDragging)
                    .padding(framePadding)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10 + framePadding,
                                                                style: .continuous))
                    .glassCardEdge(in: RoundedRectangle(cornerRadius: 10 + framePadding,
                                                        style: .continuous))

                PreviewToolbar(model: model, circularButtons: true)
                    .padding(6)
                    .glassEffect(.regular, in: Capsule())
                    .glassCardEdge(in: Capsule())
            }
        }
        .scaleEffect(appeared ? 1 : 0.92, anchor: .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }
}
