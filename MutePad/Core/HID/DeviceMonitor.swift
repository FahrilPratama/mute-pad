import Combine
import Foundation
import IOKit.hid

/// Enumerates connected pointing HID devices via `IOHIDManager` (without registering input value
/// callbacks, so macOS never requires Input Monitoring permission).
final class DeviceMonitor: ObservableObject {
    @Published private(set) var knownDevices: [HIDDeviceModel] = []
    @Published private(set) var hasBuiltInTrackpad: Bool = false

    /// Called on the main queue whenever the connection state of whitelisted external mice changes.
    var onWhitelistedMouseConnectionChanged: ((Bool) -> Void)?

    private let userDefaultsKey = "MutePad.KnownExternalMice"
    private var hidManager: IOHIDManager?

    /// Tracks active `IOHIDDevice` references per `"0xVVVV:0xPPPP"` device ID so composite
    /// dongles exposing both Mouse and Pointer interfaces are deduplicated cleanly.
    private var activeInterfacesByDeviceID: [String: Set<UnsafeRawPointer>] = [:]
    private var builtInTrackpadInterfaces: Set<UnsafeRawPointer> = []

    var hasConnectedWhitelistedMouse: Bool {
        knownDevices.contains { $0.isConnected && $0.isWhitelisted }
    }

    init() {
        loadPersistedDevices()
    }

    deinit {
        stop()
    }

    func start() {
        guard hidManager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager

        // Match only Mouse (0x02) and Pointer (0x01) for device enumeration.
        let matchingCriteria: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleDeviceMatched(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleDeviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            NSLog("MutePad: IOHIDManagerOpen enumeration returned status %d", result)
        }
    }

    func stop() {
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        activeInterfacesByDeviceID.removeAll()
        builtInTrackpadInterfaces.removeAll()
    }

    /// Toggles whether a known external mouse triggers auto-lock when connected.
    func setWhitelisted(_ whitelisted: Bool, for deviceID: String) {
        guard let index = knownDevices.firstIndex(where: { $0.id == deviceID }) else { return }
        knownDevices[index].isWhitelisted = whitelisted
        savePersistedDevices()
        notifyWhitelistStateChanged()
    }

    /// Removes an offline device from the saved whitelist.
    func removeDevice(id deviceID: String) {
        knownDevices.removeAll { $0.id == deviceID && !$0.isConnected }
        savePersistedDevices()
    }

    // MARK: - HID Callbacks

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let vendorID = intProperty(device, key: kIOHIDVendorIDKey) ?? 0
        let productID = intProperty(device, key: kIOHIDProductIDKey) ?? 0
        let transport = stringProperty(device, key: kIOHIDTransportKey) ?? ""
        let productName = stringProperty(device, key: kIOHIDProductKey) ?? "External Mouse"

        if isBuiltInAppleTrackpad(vendorID: vendorID, transport: transport, device: device) {
            builtInTrackpadInterfaces.insert(pointer)
            DispatchQueue.main.async {
                self.hasBuiltInTrackpad = !self.builtInTrackpadInterfaces.isEmpty
            }
            return
        }

        guard isSupportedExternalTransport(transport) else {
            return
        }

        let deviceID = String(format: "0x%04X:0x%04X", vendorID, productID)
        var interfaces = activeInterfacesByDeviceID[deviceID] ?? []
        let wasAlreadyConnected = !interfaces.isEmpty
        interfaces.insert(pointer)
        activeInterfacesByDeviceID[deviceID] = interfaces

        DispatchQueue.main.async {
            if let idx = self.knownDevices.firstIndex(where: { $0.id == deviceID }) {
                self.knownDevices[idx].isConnected = true
                self.knownDevices[idx].lastSeen = Date()
                if !productName.isEmpty {
                    self.knownDevices[idx].productName = productName
                }
                if !transport.isEmpty {
                    self.knownDevices[idx].transport = transport
                }
            } else {
                let model = HIDDeviceModel(
                    vendorID: vendorID,
                    productID: productID,
                    productName: productName,
                    transport: transport,
                    isWhitelisted: true,
                    isConnected: true,
                    lastSeen: Date()
                )
                self.knownDevices.append(model)
            }
            self.sortKnownDevices()
            self.savePersistedDevices()

            if !wasAlreadyConnected {
                self.notifyWhitelistStateChanged()
            }
        }
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()

        if builtInTrackpadInterfaces.remove(pointer) != nil {
            DispatchQueue.main.async {
                self.hasBuiltInTrackpad = !self.builtInTrackpadInterfaces.isEmpty
            }
            return
        }

        for (deviceID, var interfaces) in activeInterfacesByDeviceID {
            if interfaces.remove(pointer) != nil {
                if interfaces.isEmpty {
                    activeInterfacesByDeviceID.removeValue(forKey: deviceID)
                    DispatchQueue.main.async {
                        if let idx = self.knownDevices.firstIndex(where: { $0.id == deviceID }) {
                            self.knownDevices[idx].isConnected = false
                            self.knownDevices[idx].lastSeen = Date()
                            self.sortKnownDevices()
                            self.savePersistedDevices()
                        }
                        self.notifyWhitelistStateChanged()
                    }
                } else {
                    activeInterfacesByDeviceID[deviceID] = interfaces
                }
                break
            }
        }
    }

    // MARK: - Classification Helpers

    private func isBuiltInAppleTrackpad(vendorID: Int, transport: String, device: IOHIDDevice) -> Bool {
        let normalizedTransport = transport.uppercased()
        let isAppleVendor = vendorID == 0x05AC
        let isInternalBus = normalizedTransport == "SPI" || normalizedTransport == "FIFO"
        if isAppleVendor && isInternalBus {
            return true
        }
        if isAppleVendor,
           let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool,
           builtIn,
           normalizedTransport != "USB",
           normalizedTransport != "BLUETOOTH",
           normalizedTransport != "BLUETOOTHLOWENERGY" {
            return true
        }
        return false
    }

    private func isSupportedExternalTransport(_ transport: String) -> Bool {
        switch transport.lowercased() {
        case "usb", "bluetooth", "bluetoothlowenergy":
            return true
        default:
            return false
        }
    }

    private func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    // MARK: - Persistence & Notifications

    private func notifyWhitelistStateChanged() {
        onWhitelistedMouseConnectionChanged?(hasConnectedWhitelistedMouse)
    }

    private func sortKnownDevices() {
        knownDevices.sort { lhs, rhs in
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected && !rhs.isConnected
            }
            return lhs.productName.localizedCaseInsensitiveCompare(rhs.productName) == .orderedAscending
        }
    }

    private func loadPersistedDevices() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([HIDDeviceModel].self, from: data) else {
            return
        }
        knownDevices = decoded.map {
            var copy = $0
            copy.isConnected = false
            return copy
        }
        sortKnownDevices()
    }

    private func savePersistedDevices() {
        guard let data = try? JSONEncoder().encode(knownDevices) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
