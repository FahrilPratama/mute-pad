import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: View {
    @ObservedObject var hotkeyManager: HotkeyManager

    @State private var isRecording: Bool = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text("Toggle Shortcut")
                .font(.subheadline)

            Spacer()

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "Press keys..." : hotkeyManager.currentShortcut.displayString)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .frame(minWidth: 84)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Click to record a new global shortcut (Esc to cancel)")

            if hotkeyManager.currentShortcut != .defaultShortcut {
                Button {
                    stopRecording()
                    hotkeyManager.resetToDefault()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reset to default (Ctrl+Opt+T)")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording.
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            let carbonMods = HotkeyManager.Shortcut.carbonModifiers(from: flags)

            // Require at least one modifier key so normal typing isn't hijacked.
            guard carbonMods != 0 else {
                NSSound.beep()
                return nil
            }

            let newShortcut = HotkeyManager.Shortcut(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: carbonMods
            )
            hotkeyManager.updateShortcut(newShortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
