import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var isTrackpadLocked: Bool = false
    @Published var autoLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoLockEnabled, forKey: Keys.autoLockEnabled)
            evaluateAutoLockState()
        }
    }
    @Published var allowMultiTouchGestures: Bool {
        didSet {
            UserDefaults.standard.set(allowMultiTouchGestures, forKey: Keys.allowMultiTouchGestures)
            trackpadBlocker.updateState(
                isLocked: isTrackpadLocked,
                allowMultiTouchGestures: allowMultiTouchGestures
            )
        }
    }
    @Published var launchAtLogin: Bool = false

    let deviceMonitor = DeviceMonitor()
    let permissionManager = PermissionManager()
    let hotkeyManager = HotkeyManager()
    let trackpadBlocker = TrackpadBlocker()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let autoLockEnabled = "MutePad.AutoLockEnabled"
        static let allowMultiTouchGestures = "MutePad.AllowMultiTouchGestures"
    }

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.autoLockEnabled) == nil {
            defaults.set(true, forKey: Keys.autoLockEnabled)
        }
        if defaults.object(forKey: Keys.allowMultiTouchGestures) == nil {
            defaults.set(true, forKey: Keys.allowMultiTouchGestures)
        }
        self.autoLockEnabled = defaults.bool(forKey: Keys.autoLockEnabled)
        self.allowMultiTouchGestures = defaults.bool(forKey: Keys.allowMultiTouchGestures)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupCallbacks()
        setupFailSafeObservers()
        refreshLaunchAtLoginState()

        permissionManager.startPollingIfNeeded()
        deviceMonitor.start()
        hotkeyManager.registerCurrentShortcut()

        // Evaluate initial state once HID devices finish initial enumeration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.evaluateAutoLockState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unlockTrackpad()
        trackpadBlocker.stop()
        deviceMonitor.stop()
        hotkeyManager.unregister()
    }

    // MARK: - Trackpad Lock Control

    func toggleTrackpadLock() {
        if isTrackpadLocked {
            unlockTrackpad()
        } else {
            lockTrackpad()
        }
    }

    func lockTrackpad() {
        guard !isTrackpadLocked else { return }
        permissionManager.refreshStatus()
        guard permissionManager.isAccessibilityGranted else {
            permissionManager.startPollingIfNeeded()
            openPopover()
            return
        }

        isTrackpadLocked = true
        trackpadBlocker.updateState(
            isLocked: true,
            allowMultiTouchGestures: allowMultiTouchGestures
        )
        updateStatusItemIcon()
    }

    func unlockTrackpad() {
        guard isTrackpadLocked else { return }
        isTrackpadLocked = false
        trackpadBlocker.updateState(
            isLocked: false,
            allowMultiTouchGestures: allowMultiTouchGestures
        )
        updateStatusItemIcon()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginState()
        } catch {
            NSLog("MutePad: Failed to update Launch at Login: %@", error.localizedDescription)
            refreshLaunchAtLoginState()
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
        updateStatusItemIcon()
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 348, height: 500)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                appDelegate: self,
                deviceMonitor: deviceMonitor,
                permissionManager: permissionManager,
                hotkeyManager: hotkeyManager
            )
        )
        self.popover = popover
    }

    private func setupCallbacks() {
        deviceMonitor.onWhitelistedMouseConnectionChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAutoLockState()
            }
        }

        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleTrackpadLock()
            }
        }

        trackpadBlocker.onTapCreationFailed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.unlockTrackpad()
                self?.permissionManager.refreshStatus()
                self?.permissionManager.startPollingIfNeeded()
            }
        }

        trackpadBlocker.onEmergencyUnlock = { [weak self] in
            Task { @MainActor [weak self] in
                self?.unlockTrackpad()
            }
        }

        permissionManager.$isAccessibilityGranted
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] granted in
                if granted {
                    self?.evaluateAutoLockState()
                }
            }
            .store(in: &cancellables)
    }

    private func setupFailSafeObservers() {
        // Fail-safe: unlock trackpad before Mac enters sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.unlockTrackpad()
            }
        }

        // Re-evaluate auto-lock after waking from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAutoLockState()
            }
        }
    }

    private func evaluateAutoLockState() {
        guard autoLockEnabled else { return }

        if deviceMonitor.hasConnectedWhitelistedMouse {
            if permissionManager.isAccessibilityGranted {
                lockTrackpad()
            }
        } else {
            // Fail-safe: automatically unlock when all whitelisted mice disconnect.
            if isTrackpadLocked {
                unlockTrackpad()
            }
        }
    }

    private func refreshLaunchAtLoginState() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName = isTrackpadLocked ? "computermouse.fill" : "hand.point.up.left.fill"
        let description = isTrackpadLocked ? "MutePad: Trackpad Locked" : "MutePad: Trackpad Active"

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            permissionManager.refreshStatus()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func openPopover() {
        guard let popover, let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }
}
