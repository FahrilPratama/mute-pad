import AppKit
import Combine
import CryptoKit
import Foundation

/// Checks GitHub Releases for newer MutePad versions, verifies downloaded release archives
/// via SHA-256 checksum and code signature checks, and performs atomic self-replacement.
@MainActor
final class UpdateManager: ObservableObject {
    struct ReleaseInfo: Equatable {
        let version: String
        let tagName: String
        let htmlURL: URL
        let zipURL: URL
        let sha256SumsURL: URL?
        let releaseNotes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var availableUpdate: ReleaseInfo?

    /// Invoked right before the running app exits to apply an update (e.g. unlock trackpad).
    var onBeforeSelfUpdateTerminate: (() -> Void)?

    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/FahrilPratama/mute-pad/releases/latest")!
    private static let lastCheckTimestampKey = "MutePad.LastUpdateCheckTimestamp"
    private static let didJustSelfUpdateKey = "MutePad.DidJustSelfUpdate"
    private static let autoCheckInterval: TimeInterval = 6 * 60 * 60

    private var upToDateResetWorkItem: DispatchWorkItem?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .available, .failed:
            return false
        }
    }

    static func consumeDidJustSelfUpdateFlag() -> Bool {
        let defaults = UserDefaults.standard
        let didUpdate = defaults.bool(forKey: didJustSelfUpdateKey)
        if didUpdate {
            defaults.removeObject(forKey: didJustSelfUpdateKey)
        }
        return didUpdate
    }

    func checkForUpdatesIfDue() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckTimestampKey)
        let now = Date().timeIntervalSince1970
        guard lastCheck == 0 || (now - lastCheck) >= Self.autoCheckInterval else {
            return
        }
        checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool = true) {
        guard !isBusy else { return }

        upToDateResetWorkItem?.cancel()
        upToDateResetWorkItem = nil
        state = .checking

        Task { [weak self] in
            await self?.performUpdateCheck(manual: manual)
        }
    }

    func installAvailableUpdate() {
        guard let info = availableUpdate, !isBusy else { return }

        let targetAppURL = Bundle.main.bundleURL
        if let blockerReason = selfUpdateEligibilityError(for: targetAppURL) {
            state = .failed(blockerReason)
            return
        }

        Task { [weak self] in
            await self?.downloadVerifyAndApply(info: info, targetAppURL: targetAppURL)
        }
    }

    func dismissStatusMessage() {
        if let info = availableUpdate {
            state = .available(info)
        } else {
            state = .idle
        }
    }

    // MARK: - Update Check

    private func performUpdateCheck(manual: Bool) async {
        do {
            var request = URLRequest(url: Self.latestReleaseAPIURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MutePad/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.httpStatus(code)
            }

            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckTimestampKey)

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if release.draft || release.prerelease {
                handleNoUpdateFound(manual: manual)
                return
            }

            let remoteVersion = Self.normalizeVersion(release.tagName)
            guard Self.isVersion(remoteVersion, newerThan: currentVersion) else {
                handleNoUpdateFound(manual: manual)
                return
            }

            guard let zipAsset = release.assets.first(where: { $0.name == "MutePad.zip" }),
                  let zipURL = URL(string: zipAsset.browserDownloadURL),
                  Self.isAllowedDownloadURL(zipURL),
                  let htmlURL = URL(string: release.htmlURL) else {
                throw UpdateError.missingReleaseAsset
            }

            let shaURL = release.assets
                .first(where: { $0.name == "SHA256SUMS.txt" })
                .flatMap { URL(string: $0.browserDownloadURL) }
                .flatMap { Self.isAllowedDownloadURL($0) ? $0 : nil }

            let info = ReleaseInfo(
                version: remoteVersion,
                tagName: release.tagName,
                htmlURL: htmlURL,
                zipURL: zipURL,
                sha256SumsURL: shaURL,
                releaseNotes: release.body ?? ""
            )

            availableUpdate = info
            state = .available(info)
        } catch {
            if manual {
                state = .failed(error.localizedDescription)
            } else {
                state = availableUpdate.map(State.available) ?? .idle
            }
        }
    }

    private func handleNoUpdateFound(manual: Bool) {
        availableUpdate = nil
        if manual {
            state = .upToDate
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .upToDate else { return }
                self.state = .idle
            }
            upToDateResetWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
        } else {
            state = .idle
        }
    }

    // MARK: - Download, Verification, and Atomic Swap

    private func downloadVerifyAndApply(info: ReleaseInfo, targetAppURL: URL) async {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutePadUpdate-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            state = .downloading(info)

            let zipFileURL = stagingDir.appendingPathComponent("MutePad.zip")
            let zipData = try await downloadVerifiedData(from: info.zipURL)
            try zipData.write(to: zipFileURL, options: .atomic)

            if let shaURL = info.sha256SumsURL {
                let sumsData = try await downloadVerifiedData(from: shaURL)
                guard let sumsText = String(data: sumsData, encoding: .utf8),
                      let expectedDigest = Self.parseSHA256(forAssetNamed: "MutePad.zip", in: sumsText) else {
                    throw UpdateError.checksumMissing
                }

                let actualDigest = SHA256.hash(data: zipData)
                    .map { String(format: "%02x", $0) }
                    .joined()

                guard actualDigest == expectedDigest else {
                    throw UpdateError.checksumMismatch
                }
            }

            state = .installing(info)

            let extractedDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)

            try await runProcess("/usr/bin/ditto", arguments: ["-xk", zipFileURL.path, extractedDir.path])

            let stagedAppURL = extractedDir.appendingPathComponent("MutePad.app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: stagedAppURL.path),
                  let stagedBundle = Bundle(url: stagedAppURL),
                  stagedBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError.invalidExtractedBundle
            }

            // Clear quarantine and validate bundle signature before swapping.
            _ = try? await runProcess("/usr/bin/xattr", arguments: ["-cr", stagedAppURL.path])
            try await runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagedAppURL.path])

            UserDefaults.standard.set(true, forKey: Self.didJustSelfUpdateKey)

            do {
                try launchDetachedReplacementScript(
                    currentPID: ProcessInfo.processInfo.processIdentifier,
                    targetAppPath: targetAppURL.path,
                    stagedAppPath: stagedAppURL.path,
                    stagingDirPath: stagingDir.path
                )
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.didJustSelfUpdateKey)
                throw error
            }

            onBeforeSelfUpdateTerminate?()
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            state = .failed(error.localizedDescription)
        }
    }

    private func downloadVerifiedData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        request.setValue("MutePad/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.httpStatus(code)
        }

        if let finalURL = response.url, !Self.isAllowedDownloadURL(finalURL) {
            throw UpdateError.untrustedHost
        }

        return data
    }

    private func selfUpdateEligibilityError(for appURL: URL) -> String? {
        let path = appURL.path
        if appURL.pathExtension != "app" {
            return "In-app update requires running from MutePad.app."
        }
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return "Move MutePad.app to /Applications first to enable auto-update."
        }
        let parentDir = appURL.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: parentDir.path) ||
            !FileManager.default.isWritableFile(atPath: path) {
            return "Install folder is not writable. Update via Homebrew or GitHub Releases."
        }
        return nil
    }

    private func launchDetachedReplacementScript(
        currentPID: Int32,
        targetAppPath: String,
        stagedAppPath: String,
        stagingDirPath: String
    ) throws {
        let script = """
        pid="$1"
        target="$2"
        staged="$3"
        workdir="$4"
        backup="${target}.backup-$$"

        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        rm -rf "$backup"
        if [ -e "$target" ]; then
            mv "$target" "$backup" || exit 1
        fi

        if mv "$staged" "$target"; then
            rm -rf "$backup"
            /usr/bin/xattr -cr "$target" 2>/dev/null || true
            /usr/bin/open -n "$target"
        else
            if [ -e "$backup" ] && [ ! -e "$target" ]; then
                mv "$backup" "$target"
            fi
            rm -rf "$workdir"
            exit 1
        fi

        rm -rf "$workdir"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "mutepad-updater", "\(currentPID)", targetAppPath, stagedAppPath, stagingDirPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func runProcess(_ executablePath: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: UpdateError.helperFailed(executablePath, process.terminationStatus))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    static func isVersion(_ remoteRaw: String, newerThan localRaw: String) -> Bool {
        let remoteCore = normalizeVersion(remoteRaw).split(separator: "-", maxSplits: 1)[0]
        let localCore = normalizeVersion(localRaw).split(separator: "-", maxSplits: 1)[0]

        let remoteParts = remoteCore.split(separator: ".").map { Int($0) ?? 0 }
        let localParts = localCore.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(remoteParts.count, localParts.count)

        for idx in 0 ..< count {
            let r = idx < remoteParts.count ? remoteParts[idx] : 0
            let l = idx < localParts.count ? localParts[idx] : 0
            if r != l {
                return r > l
            }
        }
        return false
    }

    static func parseSHA256(forAssetNamed assetName: String, in sumsText: String) -> String? {
        for rawLine in sumsText.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let fileToken = String(parts[1])
            let baseName = (fileToken as NSString).lastPathComponent
            if baseName == assetName {
                let digest = parts[0].lowercased()
                if digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) {
                    return digest
                }
            }
        }
        return nil
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com" ||
            host.hasSuffix(".github.com") ||
            host.hasSuffix(".githubusercontent.com")
    }

    // MARK: - Models & Errors

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case missingReleaseAsset
        case untrustedHost
        case checksumMissing
        case checksumMismatch
        case invalidExtractedBundle
        case helperFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "Update server returned HTTP \(code)."
            case .missingReleaseAsset:
                return "Release package MutePad.zip was not found."
            case .untrustedHost:
                return "Download redirected to an untrusted host."
            case .checksumMissing:
                return "Could not find MutePad.zip checksum in SHA256SUMS.txt."
            case .checksumMismatch:
                return "Downloaded archive failed SHA-256 verification."
            case .invalidExtractedBundle:
                return "Downloaded MutePad.app bundle is invalid."
            case .helperFailed(let tool, let status):
                return "Update helper \((tool as NSString).lastPathComponent) failed (\(status))."
            }
        }
    }
}
