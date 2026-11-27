import AppKit
import ApplicationServices
import Combine

/// Monitors and requests macOS Accessibility permission.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool = false

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

    /// Re-evaluates Accessibility permission without emitting redundant Combine notifications.
    func refreshStatus() {
        let axGranted = AXIsProcessTrusted()
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPollingIfNeeded()
    }
}
