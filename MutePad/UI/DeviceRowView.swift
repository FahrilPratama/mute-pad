import SwiftUI

struct DeviceRowView: View {
    let device: HIDDeviceModel
    let onToggleWhitelist: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { device.isWhitelisted },
                    set: { onToggleWhitelist($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(device.isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)

                    Text(device.productName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    Text(device.transportDisplay)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(device.vidPidDisplay)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !device.isConnected {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove offline device from whitelist")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(device.isConnected ? Color.accentColor.opacity(0.06) : Color.clear)
        )
    }
}
