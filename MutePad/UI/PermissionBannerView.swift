import SwiftUI

struct PermissionBannerView: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Permissions Required")
                    .font(.headline)
                Spacer()
                Button {
                    permissionManager.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh permission status")
            }

            if !permissionManager.isAccessibilityGranted {
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Required to intercept built-in trackpad events.",
                    action: { permissionManager.requestAccessibilityPermission() }
                )
            } else if !permissionManager.isInputMonitoringGranted {
                permissionRow(
                    title: "Input Monitoring",
                    subtitle: "Click + in System Settings to add MutePad.app if not listed.",
                    action: { permissionManager.requestInputMonitoringPermission() }
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings", action: action)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
    }
}
