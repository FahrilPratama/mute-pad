import Combine
import Foundation
import IOKit
import IOKit.hid

/// Enumerates connected pointing HID devices via `IOHIDManager` (without registering input value
/// callbacks, so macOS never requires Input Monitoring permission).
final class DeviceMonitor: ObservableObject {
    @Published private(set) var knownDevices: [HIDDeviceModel] = []
    @Published private(set) var hasBuiltInTrackpad: Bool = false

    /// Called on the main queue whenever the connection state of whitelisted external mice changes.
    var onWhitelistedMouseConnectionChanged: ((Bool) -> Void)?
    /// Called whenever the set of IORegistry sender IDs belonging to the built-in trackpad changes.
    var onBuiltInTrackpadSenderIDsChanged: ((Set<UInt64>) -> Void)?

    private let userDefaultsKey = "MutePad.KnownExternalMice"
    private var hidManager: IOHIDManager?

    /// Tracks active `IOHIDDevice` references per `"0xVVVV:0xPPPP"` device ID so composite
    /// dongles exposing both Mouse and Pointer interfaces are deduplicated cleanly.
    private var activeInterfacesByDeviceID: [String: Set<UnsafeRawPointer>] = [:]
    private var builtInTrackpadInterfaces: Set<UnsafeRawPointer> = []
    private var builtInTrackpadSenderIDsByInterface: [UnsafeRawPointer: Set<UInt64>] = [:]

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

        // Match all HID devices so mice advertising pointer usages inside DeviceUsagePairs
        // (such as Logitech Options+ virtual/BLE devices) are not missed.
        IOHIDManagerSetDeviceMatching(manager, nil)

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
        builtInTrackpadSenderIDsByInterface.removeAll()
        notifyBuiltInTrackpadSenderIDsChanged()
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
        let isPointer = isMouseOrPointerDevice(device)
        let isBuiltInVendorTrackpad = isBuiltInTrackpadVendorInterface(device)
        guard isPointer || isBuiltInVendorTrackpad else { return }

        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let vendorID = intProperty(device, key: kIOHIDVendorIDKey) ?? 0
        let productID = intProperty(device, key: kIOHIDProductIDKey) ?? 0
        let transport = stringProperty(device, key: kIOHIDTransportKey) ?? ""
        let productName = stringProperty(device, key: kIOHIDProductKey) ?? "External Mouse"

        if isBuiltInDevice(transport: transport, device: device) {
            if vendorID == 0x05AC {
                builtInTrackpadInterfaces.insert(pointer)
                let service = IOHIDDeviceGetService(device)
                if service != 0 {
                    builtInTrackpadSenderIDsByInterface[pointer] = collectDescendantRegistryIDs(from: service)
                    notifyBuiltInTrackpadSenderIDsChanged()
                }
                DispatchQueue.main.async {
                    self.hasBuiltInTrackpad = !self.builtInTrackpadInterfaces.isEmpty
                }
            }
            return
        }

        guard isPointer else { return }

        // Never treat Apple vendor internal peripherals (e.g. Keyboard Backlight) as external mice.
        if vendorID == 0x05AC && productName.localizedCaseInsensitiveContains("Backlight") {
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
            builtInTrackpadSenderIDsByInterface.removeValue(forKey: pointer)
            notifyBuiltInTrackpadSenderIDsChanged()
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

    private func isMouseOrPointerDevice(_ device: IOHIDDevice) -> Bool {
        if let primaryPage = intProperty(device, key: kIOHIDPrimaryUsagePageKey),
           let primaryUsage = intProperty(device, key: kIOHIDPrimaryUsageKey),
           primaryPage == kHIDPage_GenericDesktop,
           primaryUsage == kHIDUsage_GD_Mouse || primaryUsage == kHIDUsage_GD_Pointer {
            return true
        }

        if let usagePairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
            for pair in usagePairs {
                let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue
                let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
                if page == kHIDPage_GenericDesktop,
                   usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer {
                    return true
                }
            }
        }

        return false
    }

    private func isBuiltInDevice(transport: String, device: IOHIDDevice) -> Bool {
        if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool,
           builtIn {
            return true
        }

        let normalizedTransport = transport.uppercased()
        return normalizedTransport == "SPI" || normalizedTransport == "FIFO"
    }

    private func isBuiltInTrackpadVendorInterface(_ device: IOHIDDevice) -> Bool {
        guard let vendorID = intProperty(device, key: kIOHIDVendorIDKey), vendorID == 0x05AC,
              let primaryPage = intProperty(device, key: kIOHIDPrimaryUsagePageKey), primaryPage == 0xFF00 else {
            return false
        }
        let transport = (stringProperty(device, key: kIOHIDTransportKey) ?? "").uppercased()
        let productName = stringProperty(device, key: kIOHIDProductKey) ?? ""
        guard transport == "SPI" || transport == "FIFO" else { return false }
        return !productName.localizedCaseInsensitiveContains("Backlight")
    }

    /// Walks the IORegistry `kIOServicePlane` subtree from a matched `IOHIDDevice` so descendant
    /// driver/service nodes (such as `AppleMultitouchDevice`, whose registry ID appears in
    /// `CGEventField(87)`) are resolved dynamically on any Mac without hardcoding IDs.
    private func collectDescendantRegistryIDs(from root: io_registry_entry_t) -> Set<UInt64> {
        var result: Set<UInt64> = []
        var visited: Set<UInt64> = []
        var stack: [io_registry_entry_t] = []

        var rootID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(root, &rootID) == KERN_SUCCESS {
            result.insert(rootID)
            visited.insert(rootID)
        }

        var rootIter: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(root, kIOServicePlane, &rootIter) == KERN_SUCCESS {
            var child = IOIteratorNext(rootIter)
            while child != 0 {
                stack.append(child)
                child = IOIteratorNext(rootIter)
            }
            IOObjectRelease(rootIter)
        }

        while let entry = stack.popLast() {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS,
               visited.insert(entryID).inserted {
                result.insert(entryID)
                var childIter: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS {
                    var child = IOIteratorNext(childIter)
                    while child != 0 {
                        stack.append(child)
                        child = IOIteratorNext(childIter)
                    }
                    IOObjectRelease(childIter)
                }
            }
            IOObjectRelease(entry)
        }

        return result
    }

    private func notifyBuiltInTrackpadSenderIDsChanged() {
        var merged: Set<UInt64> = []
        for ids in builtInTrackpadSenderIDsByInterface.values {
            merged.formUnion(ids)
        }
        onBuiltInTrackpadSenderIDsChanged?(merged)
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
        knownDevices = decoded
            .filter { !($0.vendorID == 0x05AC && $0.productName.localizedCaseInsensitiveContains("Backlight")) }
            .map {
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
