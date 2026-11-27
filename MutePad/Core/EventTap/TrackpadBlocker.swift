import AppKit
import CoreGraphics
import Foundation
import os

/// Intercepts built-in trackpad pointer, click, scroll, and optionally multi-touch gesture events
/// via a user-space `CGEventTap` while passing external mouse events through with zero added latency.
final class TrackpadBlocker {
    /// `NX_SUBTYPE_MOUSE_TOUCH` from `<IOKit/hidsystem/IOLLEvent.h>`.
    private static let nxSubtypeMouseTouch: Int64 = 3
    /// Undocumented but stable CoreGraphics gesture event types (`kCGEventGesture`, `kCGEventFluidTouchGesture`).
    private static let gestureEventTypeRaw: UInt32 = 29
    private static let fluidGestureEventTypeRaw: UInt32 = 31

    private struct ConfigSnapshot {
        var isLocked: Bool = false
        var allowMultiTouchGestures: Bool = true
    }

    private var configLock = os_unfair_lock_s()
    private var config = ConfigSnapshot()

    private weak var deviceMonitor: DeviceMonitor?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onTapCreationFailed: (() -> Void)?

    init(deviceMonitor: DeviceMonitor) {
        self.deviceMonitor = deviceMonitor
    }

    deinit {
        stop()
    }

    func updateState(isLocked: Bool, allowMultiTouchGestures: Bool) {
        os_unfair_lock_lock(&configLock)
        config.isLocked = isLocked
        config.allowMultiTouchGestures = allowMultiTouchGestures
        os_unfair_lock_unlock(&configLock)

        if isLocked {
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

        let mouseEvents: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .scrollWheel,
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged
        ]

        var eventMask: CGEventMask = mouseEvents.reduce(0) { mask, type in
            mask | (1 << type.rawValue)
        }
        // Include gesture masks so we can optionally block multi-touch gestures when configured.
        eventMask |= (1 << Self.gestureEventTypeRaw)
        eventMask |= (1 << Self.fluidGestureEventTypeRaw)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
            DispatchQueue.main.async {
                self.onTapCreationFailed?()
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    func stop() {
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

        os_unfair_lock_lock(&configLock)
        let currentConfig = config
        os_unfair_lock_unlock(&configLock)

        guard currentConfig.isLocked else {
            return Unmanaged.passUnretained(event)
        }

        // Handle multi-touch gesture events (e.g., 3/4-finger swipe between spaces, Mission Control).
        if type.rawValue == Self.gestureEventTypeRaw || type.rawValue == Self.fluidGestureEventTypeRaw {
            if currentConfig.allowMultiTouchGestures {
                return Unmanaged.passUnretained(event)
            }
            if isFromBuiltInTrackpad(event: event, type: type, isGesture: true) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if isFromBuiltInTrackpad(event: event, type: type, isGesture: false) {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    /// Combines CGEvent subtype inspection (`NX_SUBTYPE_MOUSE_TOUCH`), continuous scroll flags,
    /// and real-time `IOHIDManager` input timestamps to distinguish built-in trackpad events
    /// from external mouse events accurately.
    private func isFromBuiltInTrackpad(event: CGEvent, type: CGEventType, isGesture: Bool) -> Bool {
        let recentSource = deviceMonitor?.classifyRecentInputSource() ?? .unknown
        let subtype = event.getIntegerValueField(.mouseEventSubtype)

        if isGesture {
            return recentSource != .externalMouse
        }

        if subtype == Self.nxSubtypeMouseTouch {
            // Touch-generated mouse event: drop unless an external touch mouse (e.g. Magic Mouse)
            // was unmistakably the sole recent HID source.
            return recentSource != .externalMouse
        }

        if type == .scrollWheel {
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            if isContinuous && recentSource != .externalMouse {
                return true
            }
        }

        // Fallback for non-touch-subtype clicks/drags from the built-in trackpad.
        if recentSource == .builtInTrackpad {
            return true
        }

        return false
    }
}
