import AppKit
import SwiftUI

/// A transparent drag source that lets the user drag the captured screenshot out
/// of the preview card and drop it into another app (Finder, Terminal, Mail, an
/// image editor…). Overlay it on top of the SwiftUI thumbnail so the card keeps
/// its own styling and this view only catches the drag.
///
/// It's an AppKit view rather than SwiftUI's `.onDrag` because we need real
/// `NSDraggingSource` callbacks for the *start* and *end* of the drag —
/// `.onDrag` gives no reliable "ended" hook, and the card uses one to show
/// feedback and to keep itself alive (pause auto-dismiss) while the drag is in
/// flight.
struct DraggableImage: NSViewRepresentable {
    let image: NSImage
    /// The on-disk file dragged to the destination (a real file URL, so Finder
    /// copies the file and Terminal inserts its path).
    let fileURL: URL
    /// Reports drag start (`true`) and end (`false`).
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: DragSourceView) {
        view.image = image
        view.fileURL = fileURL
        view.onDragStateChange = onDragStateChange
    }
}

/// The drag-catcher. Begins a copy drag on `mouseDown`, drawing the screenshot
/// itself as the drag image so the user sees what they're carrying.
final class DragSourceView: NSView, NSDraggingSource {
    var image: NSImage?
    var fileURL: URL?
    var onDragStateChange: ((Bool) -> Void)?

    /// Start the drag on the very first click, even when the panel isn't the
    /// key window yet — otherwise the first click is swallowed just to focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hint that the thumbnail is grabbable.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let fileURL, let image else { return }

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let dragSize = draggingImageSize(for: image.size)
        let center = convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: center.x - dragSize.width / 2,
            y: center.y - dragSize.height / 2,
            width: dragSize.width,
            height: dragSize.height
        )
        item.setDraggingFrame(frame, contents: image)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStateChange?(true)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragStateChange?(false)
    }

    /// Scale the screenshot down to a tidy cursor-following thumbnail, preserving
    /// aspect ratio (never scaling up tiny captures).
    private func draggingImageSize(for size: NSSize, maxDimension: CGFloat = 168) -> NSSize {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return NSSize(width: maxDimension, height: maxDimension) }
        let scale = min(1, maxDimension / longest)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}
