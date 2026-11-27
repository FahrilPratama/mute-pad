import SwiftUI

struct PermissionBannerView: View {
    @ObservedObject var permissionManager: PermissionManager
    var onBeforeOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Permission Required")
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
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.subheadline.weight(.semibold))
                        Text("Required to intercept built-in trackpad events.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings") {
                        onBeforeOpenSettings()
                        permissionManager.requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
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
}
