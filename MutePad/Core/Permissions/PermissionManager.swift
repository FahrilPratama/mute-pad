import AppKit
import ApplicationServices
import Combine

/// Monitors and requests macOS Accessibility permission, and automatically clears
/// stale ad-hoc TCC entries when the app binary changes during upgrades.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool = false

    private static let lastExecutableSignatureKey = "MutePad.LastExecutableSignature"
    private var pollTimer: Timer?

    var allPermissionsGranted: Bool {
        isAccessibilityGranted
    }

    init() {
        refreshStatus()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Detects when an ad-hoc signed app binary was updated/rebuilt and clears the stale
    /// Accessibility TCC entry if macOS rejects the new CDHash, avoiding ghost toggles.
    func resetStaleAccessibilityIfBinaryChanged() {
        let currentSignature = executableSignature()
        let previousSignature = UserDefaults.standard.string(forKey: Self.lastExecutableSignatureKey)

        if !currentSignature.isEmpty {
            UserDefaults.standard.set(currentSignature, forKey: Self.lastExecutableSignatureKey)
        }

        guard let previousSignature,
              !currentSignature.isEmpty,
              previousSignature != currentSignature,
              !AXIsProcessTrusted(),
              !TrackpadBlocker.shared.isTapActive else {
            return
        }

        resetAccessibilityTCEntry()
        refreshStatus()
    }

    /// Re-evaluates Accessibility permission without emitting redundant Combine notifications.
    func refreshStatus() {
        let axGranted = AXIsProcessTrusted() || TrackpadBlocker.shared.isTapActive
        if isAccessibilityGranted != axGranted {
            isAccessibilityGranted = axGranted
        }
    }

    /// Starts periodic polling while Accessibility permission is missing so UI updates automatically once granted.
    func startPollingIfNeeded() {
        refreshStatus()
        guard !allPermissionsGranted else {
            stopPolling()
            return
        }
        guard pollTimer == nil else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStatus()
                if self.allPermissionsGranted {
                    self.stopPolling()
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Prompts the system Accessibility dialog (which provides its own "Open System Settings" button).
    func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            resetAccessibilityTCEntry()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPollingIfNeeded()
    }

    func resetAccessibilityTCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("MutePad: Failed to run tccutil reset: %@", error.localizedDescription)
        }
    }

    private func executableSignature() -> String {
        guard let executablePath = Bundle.main.executableURL?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: executablePath) else {
            return ""
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modTime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "\(version)|\(size)|\(Int64(modTime))"
    }
}
