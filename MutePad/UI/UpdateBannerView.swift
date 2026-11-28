import AppKit
import SwiftUI

struct UpdateBannerView: View {
    @ObservedObject var updateManager: UpdateManager
    var onBeforeOpenExternal: () -> Void = {}

    var body: some View {
        switch updateManager.state {
        case .available(let info):
            availableCard(info: info, busyLabel: nil)
        case .downloading(let info):
            availableCard(info: info, busyLabel: "Downloading...")
        case .installing(let info):
            availableCard(info: info, busyLabel: "Installing...")
        case .upToDate:
            statusCard(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "MutePad v\(updateManager.currentVersion) is up to date",
                showDismiss: false
            )
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        updateManager.dismissStatusMessage()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                if let info = updateManager.availableUpdate {
                    HStack(spacing: 8) {
                        Button("Retry") {
                            updateManager.installAvailableUpdate()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button("Open Release") {
                            onBeforeOpenExternal()
                            NSWorkspace.shared.open(info.htmlURL)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
            )
        case .idle, .checking:
            EmptyView()
        }
    }

    private func availableCard(info: UpdateManager.ReleaseInfo, busyLabel: String?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Update Available: v\(info.version)")
                    .font(.subheadline.weight(.semibold))
                Text(busyLabel ?? "Downloads, verifies, and relaunches MutePad.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if busyLabel != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Update") {
                    updateManager.installAvailableUpdate()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func statusCard(icon: String, tint: Color, title: String, showDismiss: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)

            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if showDismiss {
                Button {
                    updateManager.dismissStatusMessage()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }
}
