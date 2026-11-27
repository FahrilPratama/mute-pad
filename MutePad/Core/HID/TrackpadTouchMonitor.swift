import Foundation
import os

/// Dynamically loads Apple's `MultitouchSupport.framework` via `dlopen`/`dlsym`
/// to track real-time finger contacts on the built-in trackpad without requiring
/// macOS Input Monitoring permission.
final class TrackpadTouchMonitor {
    static let shared = TrackpadTouchMonitor()

    struct TouchState {
        let isTrackpadTouched: Bool
        let activeFingerCount: Int
    }

    private typealias MTContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, // device
        UnsafeMutableRawPointer?, // data
        Int32,                    // nFingers
        Double,                   // timestamp
        Int32                     // frame
    ) -> Int32

    private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias MTRegisterContactFrameCallbackFn = @convention(c) (
        UnsafeMutableRawPointer,
        MTContactCallback
    ) -> Void
    private typealias MTUnregisterContactFrameCallbackFn = @convention(c) (
        UnsafeMutableRawPointer,
        MTContactCallback
    ) -> Void
    private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private static let releaseBufferSeconds: CFTimeInterval = 0.08

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var mtDeviceCreateList: MTDeviceCreateListFn?
    private var mtRegisterCallback: MTRegisterContactFrameCallbackFn?
    private var mtUnregisterCallback: MTUnregisterContactFrameCallbackFn?
    private var mtDeviceStart: MTDeviceStartFn?
    private var mtDeviceStop: MTDeviceStopFn?

    /// Retains the MTDevice objects so ARC does not deallocate them while callbacks are active.
    private var retainedDevices: [AnyObject] = []
    private var isRunning = false

    private var lock = os_unfair_lock_s()
    private var _activeFingerCount: Int = 0
    private var _lastTouchTimestamp: CFAbsoluteTime = 0

    private static let contactFrameCallback: MTContactCallback = { _, _, nFingers, _, _ in
        TrackpadTouchMonitor.shared.updateFingerCount(Int(nFingers))
        return 0
    }

    var activeFingerCount: Int {
        os_unfair_lock_lock(&lock)
        let count = _activeFingerCount
        os_unfair_lock_unlock(&lock)
        return count
    }

    var isTrackpadTouched: Bool {
        currentTouchState().isTrackpadTouched
    }

    private init() {
        loadFrameworkIfNeeded()
    }

    deinit {
        stop()
        if let handle = frameworkHandle {
            dlclose(handle)
        }
    }

    func currentTouchState() -> TouchState {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        let count = _activeFingerCount
        let lastTime = _lastTouchTimestamp
        os_unfair_lock_unlock(&lock)

        let touched = count > 0 || (now - lastTime) < Self.releaseBufferSeconds
        return TouchState(isTrackpadTouched: touched, activeFingerCount: count)
    }

    func start() {
        guard !isRunning else { return }
        loadFrameworkIfNeeded()

        guard let createList = mtDeviceCreateList,
              let registerCallback = mtRegisterCallback,
              let deviceStart = mtDeviceStart,
              let deviceListUnmanaged = createList() else {
            NSLog("MutePad: MultitouchSupport symbols unavailable.")
            return
        }

        let devices = deviceListUnmanaged.takeRetainedValue() as [AnyObject]
        retainedDevices = devices

        for device in retainedDevices {
            let devicePtr = Unmanaged.passUnretained(device).toOpaque()
            registerCallback(devicePtr, Self.contactFrameCallback)
            deviceStart(devicePtr, 0)
        }

        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        for device in retainedDevices {
            let devicePtr = Unmanaged.passUnretained(device).toOpaque()
            mtUnregisterCallback?(devicePtr, Self.contactFrameCallback)
            mtDeviceStop?(devicePtr)
        }
        retainedDevices.removeAll()

        os_unfair_lock_lock(&lock)
        _activeFingerCount = 0
        _lastTouchTimestamp = 0
        os_unfair_lock_unlock(&lock)

        isRunning = false
    }

    private func updateFingerCount(_ count: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        _activeFingerCount = max(0, count)
        if count > 0 {
            _lastTouchTimestamp = now
        }
        os_unfair_lock_unlock(&lock)
    }

    private func loadFrameworkIfNeeded() {
        guard frameworkHandle == nil else { return }
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            NSLog("MutePad: Failed to load MultitouchSupport.framework")
            return
        }
        frameworkHandle = handle

        if let sym = dlsym(handle, "MTDeviceCreateList") {
            mtDeviceCreateList = unsafeBitCast(sym, to: MTDeviceCreateListFn.self)
        }
        if let sym = dlsym(handle, "MTRegisterContactFrameCallback") {
            mtRegisterCallback = unsafeBitCast(sym, to: MTRegisterContactFrameCallbackFn.self)
        }
        if let sym = dlsym(handle, "MTUnregisterContactFrameCallback") {
            mtUnregisterCallback = unsafeBitCast(sym, to: MTUnregisterContactFrameCallbackFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceStart") {
            mtDeviceStart = unsafeBitCast(sym, to: MTDeviceStartFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceStop") {
            mtDeviceStop = unsafeBitCast(sym, to: MTDeviceStopFn.self)
        }
    }
}
