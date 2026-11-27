import AppKit
import CoreGraphics
import Foundation
import os

/// Intercepts built-in trackpad pointer, click, drag, and scroll events exclusively at
/// `.cghidEventTap` using real-time finger contact state from `TrackpadTouchMonitor`,
/// anchoring the cursor via `CGWarpMouseCursorPosition` so WindowServer cannot move it.
final class TrackpadBlocker {
    struct Diagnostics {
        let tapCreationFailed: Bool
        let blockedEventCount: Int
    }

    private static let escapeKeyCode: Int64 = 53
    private static let gestureEventTypeRaw: UInt32 = 29
    private static let fluidGestureEventTypeRaw: UInt32 = 31

    private struct ConfigSnapshot {
        var isLocked: Bool = false
        var allowMultiTouchGestures: Bool = true
        var tapCreationFailed: Bool = false
        var blockedEventCount: Int = 0
        var lastAllowedCursorPosition: CGPoint?
    }

    private var configLock = os_unfair_lock_s()
    private var config = ConfigSnapshot()
    private var builtInTrackpadDeviceID: Int?

    /// Tracks recent Escape key presses for the 3x-in-1s emergency unlock fail-safe.
    private var escapePressTimestamps: [CFAbsoluteTime] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onTapCreationFailed: (() -> Void)?
    var onEmergencyUnlock: (() -> Void)?

    deinit {
        stop()
    }

    func diagnosticsSnapshot() -> Diagnostics {
        os_unfair_lock_lock(&configLock)
        let snapshot = Diagnostics(
            tapCreationFailed: config.tapCreationFailed,
            blockedEventCount: config.blockedEventCount
        )
        os_unfair_lock_unlock(&configLock)
        return snapshot
    }

    func updateState(isLocked: Bool, allowMultiTouchGestures: Bool) {
        os_unfair_lock_lock(&configLock)
        config.isLocked = isLocked
        config.allowMultiTouchGestures = allowMultiTouchGestures
        if !isLocked {
            escapePressTimestamps.removeAll()
        }
        os_unfair_lock_unlock(&configLock)

        if isLocked {
            TrackpadTouchMonitor.shared.start()
            ensureTapStarted()
        } else {
            stop()
        }
    }

    func ensureTapStarted() {
        guard eventTap == nil else {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let interceptedEvents: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .keyDown
        ]

        var eventMask: CGEventMask = interceptedEvents.reduce(0) { mask, type in
            mask | (1 << type.rawValue)
        }
        eventMask |= (1 << Self.gestureEventTypeRaw)
        eventMask |= (1 << Self.fluidGestureEventTypeRaw)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let blocker = Unmanaged<TrackpadBlocker>.fromOpaque(refcon).takeUnretainedValue()
                return blocker.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            os_unfair_lock_lock(&configLock)
            config.tapCreationFailed = true
            os_unfair_lock_unlock(&configLock)
            NSLog("MutePad: CGEvent.tapCreate(.cghidEventTap) returned nil.")
            DispatchQueue.main.async {
                self.onTapCreationFailed?()
            }
            return
        }

        os_unfair_lock_lock(&configLock)
        config.tapCreationFailed = false
        os_unfair_lock_unlock(&configLock)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        TrackpadTouchMonitor.shared.stop()

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - Event Tap Callback

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Passive Escape (keyCode 53) emergency unlock: 3 presses within 1 second.
        if type == .keyDown {
            handlePassiveKeyDown(event)
            return Unmanaged.passUnretained(event)
        }

        os_unfair_lock_lock(&configLock)
        let isLocked = config.isLocked
        let allowMultiTouchGestures = config.allowMultiTouchGestures
        let lastAllowedPos = config.lastAllowedCursorPosition
        if !isLocked {
            config.lastAllowedCursorPosition = event.location
        }
        os_unfair_lock_unlock(&configLock)

        guard isLocked else {
            return Unmanaged.passUnretained(event)
        }

        let touchMonitor = TrackpadTouchMonitor.shared
        let touchState = touchMonitor.currentTouchState()
        let sourceDeviceID = NSEvent(cgEvent: event)?.deviceID

        if touchMonitor.activeFingerCount > 0,
           let sid = sourceDeviceID,
           sid != 0 {
            os_unfair_lock_lock(&configLock)
            if builtInTrackpadDeviceID == nil {
                builtInTrackpadDeviceID = sid
            }
            os_unfair_lock_unlock(&configLock)
        }

        os_unfair_lock_lock(&configLock)
        let knownTrackpadID = builtInTrackpadDeviceID
        os_unfair_lock_unlock(&configLock)

        // If we know the built-in trackpad's deviceID and this event has a different
        // valid deviceID, it is guaranteed to come from an external mouse.
        if let knownTrackpadID,
           let sid = sourceDeviceID,
           sid != knownTrackpadID {
            os_unfair_lock_lock(&configLock)
            config.lastAllowedCursorPosition = event.location
            os_unfair_lock_unlock(&configLock)
            return Unmanaged.passUnretained(event)
        }

        let isFromTrackpadSource = (knownTrackpadID == nil) || (sourceDeviceID == knownTrackpadID)

        if touchState.isTrackpadTouched && isFromTrackpadSource {
            if allowMultiTouchGestures && touchState.activeFingerCount >= 3 {
                return Unmanaged.passUnretained(event)
            }

            os_unfair_lock_lock(&configLock)
            config.blockedEventCount += 1
            os_unfair_lock_unlock(&configLock)

            if let anchorPos = lastAllowedPos {
                CGWarpMouseCursorPosition(anchorPos)
            }
            return nil
        }

        // External mouse event: update last valid cursor position and pass through.
        os_unfair_lock_lock(&configLock)
        config.lastAllowedCursorPosition = event.location
        os_unfair_lock_unlock(&configLock)

        return Unmanaged.passUnretained(event)
    }

    private func handlePassiveKeyDown(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.escapeKeyCode else { return }

        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isAutoRepeat else { return }

        let now = CFAbsoluteTimeGetCurrent()
        var shouldEmergencyUnlock = false

        os_unfair_lock_lock(&configLock)
        if config.isLocked {
            escapePressTimestamps.append(now)
            escapePressTimestamps.removeAll { now - $0 > 1.0 }
            if escapePressTimestamps.count >= 3 {
                escapePressTimestamps.removeAll()
                config.isLocked = false
                shouldEmergencyUnlock = true
            }
        }
        os_unfair_lock_unlock(&configLock)

        if shouldEmergencyUnlock {
            DispatchQueue.main.async {
                self.onEmergencyUnlock?()
            }
        }
    }
}
