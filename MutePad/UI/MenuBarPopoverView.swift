import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var deviceMonitor: DeviceMonitor
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var hotkeyManager: HotkeyManager

    @State private var tapCreationFailed: Bool = false
    @State private var activeFingerCount: Int = 0
    @State private var blockedEventCount: Int = 0

    private let diagnosticTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if !permissionManager.allPermissionsGranted {
                PermissionBannerView(
                    permissionManager: permissionManager,
                    onBeforeOpenSettings: { appDelegate.closePopover() }
                )
            }

            Divider()

            settingsSection

            Divider()

            devicesSection

            Divider()

            ShortcutRecorderView(hotkeyManager: hotkeyManager)

            Divider()

            footerSection

            diagnosticBar
        }
        .padding(14)
        .frame(width: 348)
        .onReceive(diagnosticTimer) { _ in
            refreshDiagnostics()
        }
        .onAppear {
            refreshDiagnostics()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(appDelegate.isTrackpadLocked ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14))
                    .frame(width: 36, height: 36)

                Image(systemName: appDelegate.isTrackpadLocked ? "computermouse.fill" : "hand.point.up.left.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(appDelegate.isTrackpadLocked ? Color.accentColor : Color.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MutePad")
                        .font(.headline)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(appDelegate.isTrackpadLocked ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                    Text(appDelegate.isTrackpadLocked ? "Trackpad Locked" : "Trackpad Active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                appDelegate.toggleTrackpadLock()
            } label: {
                Text(appDelegate.isTrackpadLocked ? "Unlock" : "Lock")
                    .frame(minWidth: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(appDelegate.isTrackpadLocked ? .secondary : .accentColor)
            .controlSize(.regular)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appDelegate.autoLockEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-Lock with External Mouse")
                        .font(.subheadline)
                    Text("Locks built-in trackpad when a whitelisted mouse connects.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $appDelegate.allowMultiTouchGestures) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow Multi-Touch Gestures")
                        .font(.subheadline)
                    Text("Keep desktop swipe & Mission Control gestures active.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Detected External Mice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(deviceMonitor.knownDevices.filter(\.isConnected).count) connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if deviceMonitor.knownDevices.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "computermouse")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No external mice detected yet")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Connect a USB, Bluetooth, or 2.4GHz wireless mouse to add it to your whitelist.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(deviceMonitor.knownDevices) { device in
                            DeviceRowView(
                                device: device,
                                onToggleWhitelist: { isWhitelisted in
                                    deviceMonitor.setWhitelisted(isWhitelisted, for: device.id)
                                },
                                onRemove: {
                                    deviceMonitor.removeDevice(id: device.id)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { appDelegate.launchAtLogin },
                    set: { appDelegate.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.subheadline)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.subheadline)
        }
    }

    private var diagnosticBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tapCreationFailed ? Color.red : Color.green)
                    .frame(width: 6, height: 6)
                Text(tapCreationFailed ? "HID Tap: FAILED (Toggle Accessibility OFF/ON)" : "HID Tap: Active")
                    .font(.caption2.monospaced())
                    .foregroundStyle(tapCreationFailed ? Color.red : Color.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Fingers: \(activeFingerCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            Text("Blocked: \(blockedEventCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func refreshDiagnostics() {
        let diag = appDelegate.trackpadBlocker.diagnosticsSnapshot()
        tapCreationFailed = diag.tapCreationFailed
        blockedEventCount = diag.blockedEventCount
        activeFingerCount = TrackpadTouchMonitor.shared.activeFingerCount
    }
}
