import AppKit
import OSLog
import Observation

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "LastCapture")

/// The most recently closed capture, kept as a `.prtscn` package so a discard,
/// an Esc in the editor or a replaced editor can be taken back from the menu
/// bar ("Reopen Last Capture"). One slot, overwritten by the next close and
/// cleared at quit.
///
/// Disk I/O runs on one serial queue so two closes in a row land in order.
@MainActor
@Observable
final class LastCapture {
    static let shared = LastCapture(url: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "PrtScn", isDirectory: true)
        .appendingPathComponent("LastCapture.prtscn", isDirectory: true))

    private nonisolated static let queue = DispatchQueue(label: "com.alejandrolacasa.prtscn.lastcapture")

    let url: URL
    private(set) var exists: Bool

    init(url: URL) {
        self.url = url
        exists = FileManager.default.fileExists(atPath: url.path)
    }

    /// `png` runs off the main actor, so encoding a large image never delays
    /// the close that triggered it.
    func keep(_ document: ProjectDocument, png: @escaping @Sendable () -> Data?) {
        guard let json = try? JSONEncoder().encode(document) else { return }
        exists = true
        let url = url
        Self.queue.async {
            guard let png = png() else { return }
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try png.write(to: url.appendingPathComponent(ProjectDocument.imageName))
                try json.write(to: url.appendingPathComponent(ProjectDocument.documentName))
            } catch {
                log.error("couldn't keep the last capture: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Keeps an unannotated capture; call before its temp file is deleted.
    func keep(imageAt fileURL: URL, captureScale: CGFloat) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        keep(ProjectDocument(captureScale: captureScale, nextCounter: 1, annotations: [])) { data }
    }

    func reopen() {
        waitForPendingWrites()
        EditorController.shared.reopenCapture(at: url)
    }

    func clear() {
        exists = false
        let url = url
        Self.queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    func waitForPendingWrites() {
        Self.queue.sync {}
    }
}
