import AppKit
import OSLog

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "CanvasRecovery")

/// Crash insurance for the editor: while there's work worth keeping, the
/// canvas is mirrored into a `.prtscn` package under Application Support, and
/// closing the editor deletes it. A package still there at launch is what a
/// crash (or a force quit) left behind, and gets offered back.
///
/// Disk I/O runs on one serial queue, so writes land in order and a discard
/// can never be overtaken by a write still in flight.
@MainActor
final class CanvasRecovery {
    /// The project the canvas was opened from, so a restored canvas saves
    /// back to it.
    private struct Origin: Codable {
        var documentURL: URL?
    }

    private nonisolated static let originName = "origin.json"
    private nonisolated static let queue = DispatchQueue(label: "com.alejandrolacasa.prtscn.recovery")

    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "PrtScn", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }()

    /// Which crop generation's base image each package holds on disk, so the
    /// PNG is only re-encoded after a crop replaced it — and re-attempted if
    /// writing it failed. Only touched on `queue`.
    private nonisolated(unsafe) static var imageGenerationOnDisk: [URL: Int] = [:]

    let url: URL

    /// Pass the package a crash left behind to keep writing into it, so
    /// crashing again before the next edit still loses nothing.
    init(adopting leftover: URL? = nil) {
        let url = leftover ?? Self.directory.appendingPathComponent("\(UUID().uuidString).prtscn", isDirectory: true)
        self.url = url
        if leftover != nil { Self.queue.async { Self.imageGenerationOnDisk[url] = 0 } }
    }

    func save(document: ProjectDocument, image: () -> CGImage?, imageGeneration: Int, origin: URL?) {
        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(document),
              let originJSON = try? encoder.encode(Origin(documentURL: origin)),
              let image = image() else { return }
        let box = SendableImage(image: image)
        let url = url, originName = Self.originName
        Self.queue.async {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                if Self.imageGenerationOnDisk[url] != imageGeneration {
                    guard let image = box.image,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { throw CocoaError(.fileWriteUnknown) }
                    try png.write(to: url.appendingPathComponent(ProjectDocument.imageName), options: .atomic)
                    Self.imageGenerationOnDisk[url] = imageGeneration
                }
                try json.write(to: url.appendingPathComponent(ProjectDocument.documentName), options: .atomic)
                try originJSON.write(to: url.appendingPathComponent(originName), options: .atomic)
            } catch {
                log.error("recovery snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func discard() {
        let url = url
        Self.queue.async {
            try? FileManager.default.removeItem(at: url)
            Self.imageGenerationOnDisk[url] = nil
        }
    }

    /// Blocks until every queued write and discard has landed — for when the
    /// app is about to exit.
    static func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Launch

    /// Offers back the newest canvas a crash left behind. Restore reopens it
    /// in the editor; Discard moves it to the Trash rather than deleting it.
    /// Skipped when a Finder-opened project is already in the editor; the
    /// snapshot waits for the next launch.
    static func offerRecoveryAtLaunch() {
        guard !EditorController.shared.isOpen, let url = leftovers().first else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "PrtScn quit unexpectedly while you were editing")
        alert.informativeText = String(localized: "Your canvas was saved automatically. Do you want to restore it?")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                log.error("couldn't trash recovery snapshot: \(String(describing: error), privacy: .public)")
            }
            return
        }
        let origin = (try? Data(contentsOf: url.appendingPathComponent(originName)))
            .flatMap { try? JSONDecoder().decode(Origin.self, from: $0) }?.documentURL
        EditorController.shared.recover(from: url, originalDocumentURL: origin)
    }

    /// Complete recovery packages, newest first. One missing a file is a
    /// snapshot whose first write never finished — nothing to restore.
    private static func leftovers() -> [URL] {
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return packages
            .filter { package in
                [ProjectDocument.imageName, ProjectDocument.documentName].allSatisfy {
                    FileManager.default.fileExists(atPath: package.appendingPathComponent($0).path)
                }
            }
            .sorted { modified($0) > modified($1) }
    }
}
