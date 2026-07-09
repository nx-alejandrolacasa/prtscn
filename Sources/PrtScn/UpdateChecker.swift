import AppKit
import Observation

/// Checks GitHub Releases for a newer version and, on request, installs it —
/// download the DMG, mount it, replace the app bundle, relaunch. No Sparkle,
/// no dependencies: URLSession + `hdiutil`/`ditto`, same tools a person would
/// use by hand.
///
/// Because the app downloads the DMG itself (no browser), the file carries no
/// quarantine attribute — so updating in-app sidesteps the Gatekeeper
/// "unidentified developer" dance that a manual download requires.
///
/// The dev variant never self-installs (it isn't the copy in /Applications);
/// it opens the release page instead.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Where releases live. The API call is anonymous; unauthenticated rate
    /// limits (60/hour/IP) are far above one check per day + manual retries.
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/nx-alejandrolacasa/prtscn/releases/latest")!

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The newer release found by the last check, if any.
    private(set) var latest: Release?

    struct Release: Equatable {
        let version: String   // "0.5.0" — tag with the leading "v" stripped
        let dmgURL: URL?      // the DMG asset, if the release has one
        let pageURL: URL      // the release page on github.com
    }

    private init() {}

    // MARK: - Checking

    /// The daily launch-time check: quiet (no UI phase changes on failure) and
    /// skipped if we already checked in the last 20 hours.
    func checkAutomatically() async {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date.now.timeIntervalSince1970 - last > 20 * 60 * 60 else { return }
        await check(quietly: true)
    }

    /// Fetches the latest release and compares it to the running version.
    /// With `quietly`, network errors leave the UI untouched instead of
    /// surfacing a failure the user never asked about.
    func check(quietly: Bool = false) async {
        if !quietly { phase = .checking }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "lastUpdateCheck")
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(APIRelease.self, from: data)

            let version = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isVersion(version, newerThan: Self.currentVersion) {
                latest = Release(
                    version: version,
                    dmgURL: release.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadUrl,
                    pageURL: release.htmlUrl)
                phase = .available
            } else {
                latest = nil
                if !quietly { phase = .upToDate }
            }
        } catch {
            NSLog("[PrtScn] update check failed: \(error)")
            if !quietly { phase = .failed("Couldn't check for updates.") }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Numeric, component-wise semver comparison ("0.10.0" > "0.9.1"; a plain
    /// string compare would get that wrong). Missing components count as 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// Downloads and installs the release found by the last check, then
    /// relaunches. On the dev variant (or a release without a DMG) it opens
    /// the release page instead — replacing /Applications/PrtScn.app from a
    /// dev build would clobber an app we're not running.
    func installLatest() async {
        guard let release = latest else { return }
        let isDevBuild = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        guard let dmgURL = release.dmgURL, !isDevBuild else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        do {
            phase = .downloading
            let (downloaded, _) = try await URLSession.shared.download(from: dmgURL)
            // hdiutil wants the .dmg extension to pick the right handler.
            let dmg = downloaded.deletingPathExtension().appendingPathExtension("dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            phase = .installing
            try await Self.install(dmg: dmg)
            relaunch()
        } catch {
            NSLog("[PrtScn] update install failed: \(error)")
            phase = .failed("Update failed — install manually from GitHub.")
        }
    }

    /// Mounts the DMG, copies its .app over the running bundle, unmounts.
    /// The destination is `Bundle.main.bundleURL` — the copy of the app that
    /// is actually running — not a hardcoded /Applications path.
    private static func install(dmg: URL) async throws {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("prtscn-update-\(UUID().uuidString)")
        try await run("/usr/bin/hdiutil",
                      "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                      "-mountpoint", mountPoint.path)
        defer {
            Task.detached { try? await run("/usr/bin/hdiutil", "detach", mountPoint.path) }
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInDMG
        }

        // Replacing a running app's bundle is safe on macOS — the running
        // process keeps its open files; the new bundle is picked up on
        // relaunch. `ditto` preserves the code signature, like build.sh.
        let destination = Bundle.main.bundleURL
        try FileManager.default.removeItem(at: destination)
        try await run("/usr/bin/ditto", app.path, destination.path)
    }

    /// Launches the freshly installed bundle after this process exits. The
    /// spawned shell outlives us (children aren't killed on parent exit), so
    /// `sleep 1` lets the old instance finish quitting first.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    private enum UpdateError: Error {
        case noAppInDMG
        case processFailed(String)
    }

    /// Runs a CLI tool, throwing if it exits non-zero. Continuation-based so
    /// the main actor suspends instead of blocking (same pattern as
    /// `ScreenshotService.runScreencapture`).
    private static func run(_ executable: String, _ arguments: String...) async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                NSLog("[PrtScn] \(executable) failed to launch: \(error)")
                continuation.resume(returning: -1)
            }
        }
        guard status == 0 else {
            throw UpdateError.processFailed("\(executable) exited with \(status)")
        }
    }
}

/// The slice of GitHub's release JSON we care about (snake_case-decoded).
private struct APIRelease: Decodable {
    let tagName: String
    let htmlUrl: URL
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }
}
