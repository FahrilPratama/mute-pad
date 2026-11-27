import Combine
import CoreGraphics
import Foundation
import IOKit.hid
import os

/// Monitors HID pointing devices via `IOHIDManager` to distinguish built-in Apple trackpads
/// from external mice (USB, Bluetooth, Bluetooth LE, and composite 2.4GHz wireless dongles).
final class DeviceMonitor: ObservableObject {
    enum InputSource {
        case builtInTrackpad
        case externalMouse
        case unknown
    }

    @Published private(set) var knownDevices: [HIDDeviceModel] = []
    @Published private(set) var hasBuiltInTrackpad: Bool = false

    /// Called on the main queue whenever the connection state of whitelisted external mice changes.
    var onWhitelistedMouseConnectionChanged: ((Bool) -> Void)?

    private let userDefaultsKey = "MutePad.KnownExternalMice"
    private var hidManager: IOHIDManager?
    private var lastOpenStatus: IOReturn = kIOReturnError

    /// Tracks active `IOHIDDevice` references per `"0xVVVV:0xPPPP"` device ID so composite
    /// dongles exposing both Mouse and Pointer interfaces are deduplicated cleanly.
    private var activeInterfacesByDeviceID: [String: Set<UnsafeRawPointer>] = [:]
    private var builtInTrackpadInterfaces: Set<UnsafeRawPointer> = []

    /// Lock-protected timestamps for ultra-fast, thread-safe input source correlation
    /// from the `CGEventTap` callback.
    private var activityLock = os_unfair_lock_s()
    private var lastBuiltInTrackpadInputTime: CFAbsoluteTime = 0
    private var lastExternalMouseInputTime: CFAbsoluteTime = 0

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

        // Match both Mouse (0x02) and Pointer (0x01) under Generic Desktop (0x01).
        // Composite 2.4GHz dongles expose separate Mouse/Pointer and Keyboard HID collections;
        // matching these usages reliably detects the mouse interface without picking up keyboards.
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

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            monitor.handleInputValue(from: device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        lastOpenStatus = result
        if result == kIOReturnNotPermitted {
            // -536870174 (kIOReturnNotPermitted): Input Monitoring not granted yet.
            // Handle gracefully without crashing; DeviceMonitor will re-open once granted.
            NSLog("MutePad: IOHIDManagerOpen returned kIOReturnNotPermitted (-536870174); waiting for Input Monitoring permission.")
        } else if result != kIOReturnSuccess {
            NSLog("MutePad: IOHIDManagerOpen returned status %d", result)
        }
    }

    /// Re-opens `IOHIDManager` if it previously failed with `kIOReturnNotPermitted` (-536870174)
    /// so input value callbacks activate immediately once the user grants Input Monitoring.
    func reopenIfInputMonitoringGranted() {
        guard lastOpenStatus != kIOReturnSuccess else { return }
        let granted = CGPreflightListenEventAccess()
            || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        guard granted else { return }
        stop()
        start()
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

    /// Thread-safe helper called from `TrackpadBlocker`'s `CGEventTap` callback to correlate
    /// which HID hardware generated input most recently.
    func classifyRecentInputSource(windowSeconds: CFTimeInterval = 0.12) -> InputSource {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&activityLock)
        let trackpadAge = now - lastBuiltInTrackpadInputTime
        let externalAge = now - lastExternalMouseInputTime
        os_unfair_lock_unlock(&activityLock)

        let trackpadRecent = trackpadAge <= windowSeconds
        let externalRecent = externalAge <= windowSeconds

        if trackpadRecent && !externalRecent {
            return .builtInTrackpad
        }
        if externalRecent && !trackpadRecent {
            return .externalMouse
        }
        if trackpadRecent && externalRecent {
            return trackpadAge <= externalAge ? .builtInTrackpad : .externalMouse
        }
        return .unknown
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

    private func handleInputValue(from device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let now = CFAbsoluteTimeGetCurrent()

        if builtInTrackpadInterfaces.contains(pointer) {
            os_unfair_lock_lock(&activityLock)
            lastBuiltInTrackpadInputTime = now
            os_unfair_lock_unlock(&activityLock)
            return
        }

        // Check if sender belongs to any active external mouse interface
        for interfaces in activeInterfacesByDeviceID.values where interfaces.contains(pointer) {
            os_unfair_lock_lock(&activityLock)
            lastExternalMouseInputTime = now
            os_unfair_lock_unlock(&activityLock)
            return
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
        // Fallback: Apple Silicon internal trackpads may also set kIOHIDBuiltInKey = true
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
