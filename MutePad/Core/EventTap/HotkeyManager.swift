import AppKit
import Carbon
import Combine
import Foundation

/// Registers and persists a global keyboard shortcut via Carbon `RegisterEventHotKey`.
/// Default shortcut is `Ctrl + Option + T` (`Ctrl+Opt+T`).
final class HotkeyManager: ObservableObject {
    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32

        /// Default: `Ctrl + Option + T` (`Ctrl+Opt+T`)
        static let defaultShortcut = Shortcut(
            keyCode: UInt32(kVK_ANSI_T),
            carbonModifiers: UInt32(controlKey | optionKey)
        )

        var displayString: String {
            var parts: [String] = []
            if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
            if carbonModifiers & UInt32(optionKey) != 0 { parts.append("Opt") }
            if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
            if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
            parts.append(Self.keyCodeToString(keyCode))
            return parts.joined(separator: "+")
        }

        static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            return carbon
        }

        private static func keyCodeToString(_ keyCode: UInt32) -> String {
            switch Int(keyCode) {
            case kVK_ANSI_A: return "A"
            case kVK_ANSI_B: return "B"
            case kVK_ANSI_C: return "C"
            case kVK_ANSI_D: return "D"
            case kVK_ANSI_E: return "E"
            case kVK_ANSI_F: return "F"
            case kVK_ANSI_G: return "G"
            case kVK_ANSI_H: return "H"
            case kVK_ANSI_I: return "I"
            case kVK_ANSI_J: return "J"
            case kVK_ANSI_K: return "K"
            case kVK_ANSI_L: return "L"
            case kVK_ANSI_M: return "M"
            case kVK_ANSI_N: return "N"
            case kVK_ANSI_O: return "O"
            case kVK_ANSI_P: return "P"
            case kVK_ANSI_Q: return "Q"
            case kVK_ANSI_R: return "R"
            case kVK_ANSI_S: return "S"
            case kVK_ANSI_T: return "T"
            case kVK_ANSI_U: return "U"
            case kVK_ANSI_V: return "V"
            case kVK_ANSI_W: return "W"
            case kVK_ANSI_X: return "X"
            case kVK_ANSI_Y: return "Y"
            case kVK_ANSI_Z: return "Z"
            case kVK_ANSI_0: return "0"
            case kVK_ANSI_1: return "1"
            case kVK_ANSI_2: return "2"
            case kVK_ANSI_3: return "3"
            case kVK_ANSI_4: return "4"
            case kVK_ANSI_5: return "5"
            case kVK_ANSI_6: return "6"
            case kVK_ANSI_7: return "7"
            case kVK_ANSI_8: return "8"
            case kVK_ANSI_9: return "9"
            case kVK_Space: return "Space"
            case kVK_Return: return "Return"
            case kVK_Tab: return "Tab"
            case kVK_Delete: return "Delete"
            case kVK_F1: return "F1"
            case kVK_F2: return "F2"
            case kVK_F3: return "F3"
            case kVK_F4: return "F4"
            case kVK_F5: return "F5"
            case kVK_F6: return "F6"
            case kVK_F7: return "F7"
            case kVK_F8: return "F8"
            case kVK_F9: return "F9"
            case kVK_F10: return "F10"
            case kVK_F11: return "F11"
            case kVK_F12: return "F12"
            default: return "Key(\(keyCode))"
            }
        }
    }

    @Published private(set) var currentShortcut: Shortcut

    var onHotkeyPressed: (() -> Void)?

    private let userDefaultsKey = "MutePad.GlobalShortcut"
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: FourCharCode(0x4D504144), id: 1) // 'MPAD'

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) {
            self.currentShortcut = decoded
        } else {
            self.currentShortcut = .defaultShortcut
        }
    }

    deinit {
        unregister()
    }

    func registerCurrentShortcut() {
        installEventHandlerIfNeeded()
        unregisterHotKeyOnly()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            currentShortcut.keyCode,
            currentShortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("MutePad: Failed to register hotkey (OSStatus %d)", status)
        }
    }

    func updateShortcut(_ newShortcut: Shortcut) {
        currentShortcut = newShortcut
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        registerCurrentShortcut()
    }

    func resetToDefault() {
        updateShortcut(.defaultShortcut)
    }

    func unregister() {
        unregisterHotKeyOnly()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    private func unregisterHotKeyOnly() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard err == noErr else { return err }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if receivedID.id == manager.hotKeyID.id {
                    DispatchQueue.main.async {
                        manager.onHotkeyPressed?()
                    }
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            userData,
            &handler
        )

        if status == noErr {
            eventHandlerRef = handler
        }
    }
}

private extension FourCharCode {
    init(_ value: UInt32) {
        self = value
    }
}
