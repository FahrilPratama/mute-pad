import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import IOKit.hid

/// Monitors and requests macOS Accessibility and Input Monitoring permissions.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var isInputMonitoringGranted: Bool = false

    private var pollTimer: Timer?

    var allPermissionsGranted: Bool {
        isAccessibilityGranted && isInputMonitoringGranted
    }

    init() {
        refreshStatus()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Re-evaluates both Accessibility and Input Monitoring permissions without emitting
    /// redundant Combine notifications when values have not changed.
    func refreshStatus() {
        let axGranted = AXIsProcessTrusted()
        if isAccessibilityGranted != axGranted {
            isAccessibilityGranted = axGranted
        }

        let inputGranted = CGPreflightListenEventAccess()
            || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if isInputMonitoringGranted != inputGranted {
            isInputMonitoringGranted = inputGranted
        }
    }

    /// Starts periodic polling while permissions are missing so UI updates automatically once granted.
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

    /// Prompts the system Accessibility dialog and opens System Settings if needed.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
        startPollingIfNeeded()
    }

    /// Prompts the system Input Monitoring dialog (via CoreGraphics + IOKit) so MutePad
    /// appears automatically in System Settings > Privacy & Security > Input Monitoring.
    func requestInputMonitoringPermission() {
        // Creating a temporary listen-only event tap alongside CGRequestListenEventAccess()
        // and IOHIDRequestAccess() ensures tccd registers the app in Input Monitoring.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tempTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) {
            CFMachPortInvalidate(tempTap)
        }

        _ = CGRequestListenEventAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        startPollingIfNeeded()

        // Allow tccd a brief moment to register the TCC entry before System Settings opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openInputMonitoringSettings()
        }
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
