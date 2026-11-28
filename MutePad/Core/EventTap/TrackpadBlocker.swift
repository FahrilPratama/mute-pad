import CoreGraphics
import Foundation
import os

/// Intercepts built-in trackpad pointer, click, drag, and scroll events exclusively at
/// `.cghidEventTap` using zero-allocation `CGEventField` inspection and real-time finger
/// contact state from `TrackpadTouchMonitor`, while keeping external mouse input stutter-free.
final class TrackpadBlocker {
    static let shared = TrackpadBlocker()

    struct Diagnostics {
        let tapCreationFailed: Bool
        let blockedEventCount: Int
    }

    private static let escapeKeyCode: Int64 = 53
    private static let gestureEventTypeRaw: UInt32 = 29
    private static let fluidGestureEventTypeRaw: UInt32 = 31
    private static let senderIDField = CGEventField(rawValue: 87)!
    private static let selfPID = Int64(ProcessInfo.processInfo.processIdentifier)

    private struct ConfigSnapshot {
        var isLocked: Bool = false
        var allowMultiTouchGestures: Bool = true
        var tapCreationFailed: Bool = false
        var blockedEventCount: Int = 0
        var lastAllowedCursorPosition: CGPoint?
        var builtInTrackpadSenderIDs: Set<UInt64> = []
    }

    private var configLock = os_unfair_lock_s()
    private var config = ConfigSnapshot()

    /// Tracks recent Escape key presses for the 3x-in-1s emergency unlock fail-safe.
    private var escapePressTimestamps: [CFAbsoluteTime] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onTapCreationFailed: (() -> Void)?
    var onEmergencyUnlock: (() -> Void)?

    var isTapActive: Bool {
        os_unfair_lock_lock(&configLock)
        let active = (eventTap != nil) && !config.tapCreationFailed
        os_unfair_lock_unlock(&configLock)
        return active
    }

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

    func updateBuiltInTrackpadSenderIDs(_ ids: Set<UInt64>) {
        os_unfair_lock_lock(&configLock)
        config.builtInTrackpadSenderIDs = ids
        os_unfair_lock_unlock(&configLock)
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
        let senderID = UInt64(bitPattern: event.getIntegerValueField(Self.senderIDField))
        let hasSenderIDFilter = !config.builtInTrackpadSenderIDs.isEmpty && senderID != 0
        let isBuiltInSender = hasSenderIDFilter && config.builtInTrackpadSenderIDs.contains(senderID)
        if !isLocked {
            config.lastAllowedCursorPosition = event.location
        }
        os_unfair_lock_unlock(&configLock)

        guard isLocked else {
            return Unmanaged.passUnretained(event)
        }

        // Zero-allocation fast-path for driver-injected events (e.g. Logi Options+),
        // excluding MutePad's own CGWarpMouseCursorPosition events.
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        if sourcePID > 0 && sourcePID != Self.selfPID {
            os_unfair_lock_lock(&configLock)
            config.lastAllowedCursorPosition = event.location
            os_unfair_lock_unlock(&configLock)
            return Unmanaged.passUnretained(event)
        }

        let isGestureEvent = (type.rawValue == Self.gestureEventTypeRaw || type.rawValue == Self.fluidGestureEventTypeRaw)

        // Distinguish built-in trackpad events via CGEventField(87) when available so resting
        // a palm on the trackpad while typing never blocks external mouse input; fall back to
        // MultitouchSupport contact state if senderID metadata is unavailable.
        let isFromBuiltInTrackpad: Bool
        if hasSenderIDFilter {
            isFromBuiltInTrackpad = isBuiltInSender
        } else {
            if allowMultiTouchGestures && isGestureEvent {
                return Unmanaged.passUnretained(event)
            }
            isFromBuiltInTrackpad = TrackpadTouchMonitor.shared.currentTouchState().isTrackpadTouched
        }

        guard isFromBuiltInTrackpad else {
            os_unfair_lock_lock(&configLock)
            config.lastAllowedCursorPosition = event.location
            os_unfair_lock_unlock(&configLock)
            return Unmanaged.passUnretained(event)
        }

        if allowMultiTouchGestures &&
            (isGestureEvent || TrackpadTouchMonitor.shared.currentTouchState().activeFingerCount >= 3) {
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
