import AppKit
import Observation
import Security
import os

private let log = Logger(subsystem: "com.alejandrolacasa.prtscn", category: "UpdateChecker")

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

    /// Seconds left before another manual check is allowed — counts down from
    /// `checkCooldown` after each check so the button can't hammer the GitHub
    /// API. Zero means ready.
    private(set) var cooldownRemaining = 0
    var isCoolingDown: Bool { cooldownRemaining > 0 }
    static let checkCooldown = 10
    private var cooldownTask: Task<Void, Never>?

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
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.httpStatus(http.statusCode)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(APIRelease.self, from: data)
            // Stamp only after a successful fetch, so a failed launch-time
            // check (offline, rate-limited) doesn't suppress retries for 20 h.
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "lastUpdateCheck")

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
            log.error("update check failed: \(String(describing: error), privacy: .public)")
            if !quietly { phase = .failed(String(localized: "Couldn't check for updates.")) }
        }
        if !quietly { startCooldown() }
    }

    /// Disables re-checking for `checkCooldown`; a fresh call restarts the clock.
    private func startCooldown() {
        cooldownTask?.cancel()
        cooldownRemaining = Self.checkCooldown
        cooldownTask = Task { [weak self] in
            while let self, self.cooldownRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.cooldownRemaining -= 1
            }
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
            defer { try? FileManager.default.removeItem(at: dmg) }

            phase = .installing
            try await Self.install(dmg: dmg)
        } catch UpdateError.untrustedSignature {
            phase = .failed(String(localized: "The update's code signature couldn't be verified, so it wasn't installed."))
            return
        } catch {
            log.error("update install failed: \(String(describing: error), privacy: .public)")
            phase = .failed(String(localized: "Update failed — install manually from GitHub."))
            return
        }
        relaunch()
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
        // Stage the copy next to the destination first (same volume), verify
        // it, then swap it in with `replaceItemAt` — which never leaves the
        // destination missing, unlike remove-then-move.
        let destination = Bundle.main.bundleURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).update")
        try? FileManager.default.removeItem(at: staging)
        do {
            try await run("/usr/bin/ditto", app.path, staging.path)
            try verifySignature(ofAppAt: staging)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Rejects a bundle whose signature is broken, and — when this copy is
    /// signed with a real certificate — one not satisfying our designated
    /// requirement (same identifier, same signing certificate). Ad-hoc
    /// builds (local `./build.sh install`) skip that second check: their
    /// requirement pins a cdhash no other build can match.
    private static func verifySignature(ofAppAt url: URL) throws {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &candidate) == errSecSuccess,
              let candidate
        else { throw UpdateError.untrustedSignature }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let requirement = try runningAppRequirement()
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else {
            log.error("update signature check failed (status \(status))")
            throw UpdateError.untrustedSignature
        }
    }

    /// `nil` when the running app is ad-hoc signed.
    private static func runningAppRequirement() throws -> SecRequirement? {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopySigningInformation(runningStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { throw UpdateError.untrustedSignature }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return nil }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess
        else { throw UpdateError.untrustedSignature }
        return requirement
    }

    /// Launches the freshly installed bundle once this process has exited
    /// (the spawned shell outlives us). If quitting is cancelled — an unsaved
    /// project prompt — `terminate` returns: stop the helper and let the user
    /// retry. Path and pid travel as arguments, never interpolated into the
    /// script.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        try? process.run()
        NSApp.terminate(nil)
        process.terminate()
        phase = .available
    }

    private enum UpdateError: Error {
        case untrustedSignature
        case noAppInDMG
        case processFailed(String)
        case httpStatus(Int)
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
                log.error("\(executable, privacy: .public) failed to launch: \(String(describing: error), privacy: .public)")
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
