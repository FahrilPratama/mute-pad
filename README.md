# MutePad

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![macOS 13.0+](https://img.shields.io/badge/macOS-13.0%2B-black?style=for-the-badge&logo=apple)](https://www.apple.com/macos/)
[![Buy Me a Coffee (PayPal)](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/FRprojet)

**MutePad** is a lightweight, native macOS Menu Bar utility built with **Swift** and **SwiftUI + AppKit**, optimized for **Apple Silicon (M-Series)** on **macOS 13.0 (Ventura)+**.

It automatically (or manually) disables input from your MacBook's **built-in trackpad** whenever an external mouse is connected -- including **composite 2.4GHz wireless dongles** (which register as both Mouse + Keyboard and often break macOS's built-in *"Ignore built-in trackpad when mouse or wireless trackpad is present"* setting).

---

## Features

- **Menu Bar Only (`LSUIElement`)**: Lives quietly in the Menu Bar with dynamic SF Symbols (`computermouse.fill` when locked, `hand.point.up.left.fill` when active).
- **Accurate Hardware Detection (`IOHIDManager`)**:
  - Distinguishes the internal Apple trackpad (`SPI` / `FIFO`, `VendorID 0x05AC`) from external mice (`USB`, `Bluetooth`, `BluetoothLowEnergy`).
  - Handles composite 2.4GHz wireless dongles cleanly without duplicate entries.
  - **Device Whitelist**: Saves known mice (`VendorID`, `ProductID`, `ProductName`) to `UserDefaults` so you can choose which mice trigger auto-lock (great if you leave an empty USB dongle plugged into a hub).
- **Zero-Latency Input Interception (`CGEventTap`)**:
  - Drops trackpad pointer, click, drag, and scroll events (`NX_SUBTYPE_MOUSE_TOUCH` + real-time HID activity correlation) while letting external mouse input pass through untouched.
  - Optional **Allow Multi-Touch Gestures** toggle to keep Space swipes and Mission Control working while blocking accidental palm touches.
- **Anti-Lockout Fail-Safes**:
  - Automatically unlocks the trackpad if all whitelisted mice disconnect, before the Mac enters sleep (`NSWorkspace.willSleepNotification`), or when the app quits.
  - Customizable **Global Keyboard Shortcut** (default: `Ctrl+Opt+T`) via Carbon `RegisterEventHotKey`.
- **Launch at Login**: Native `SMAppService.mainApp` integration.

---

## Installation

### 1. Via Homebrew (Recommended)

```bash
brew install --cask FahrilPratama/tap/mutepad
```

### 2. Manual Download

1. Download `MutePad.dmg` or `MutePad.zip` from the [GitHub Releases](https://github.com/FahrilPratama/mute-pad/releases) page.
2. Move `MutePad.app` to `/Applications`.
3. If macOS Gatekeeper blocks the unsigned open-source build on first launch, clear the quarantine attribute:
   ```bash
   xattr -cr /Applications/MutePad.app
   ```

### 3. Build from Source

```bash
git clone https://github.com/FahrilPratama/mute-pad.git
cd mute-pad
open MutePad.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project MutePad.xcodeproj -scheme MutePad -configuration Release build
```

---

## Required macOS Permission

MutePad uses pure user-space APIs (no kernel extensions or system modifications) and requires only **one** macOS privacy permission:

- **Accessibility (`AXIsProcessTrusted`)**: Required by `CGEventTap` (`.cghidEventTap`) to intercept and block built-in trackpad events while keeping external mouse input active.

MutePad displays an inline onboarding banner whenever Accessibility permission is missing, with a one-click button to trigger the system permission prompt.

---

## Architecture

```text
MutePad/
|-- App/
|   |-- MutePadApp.swift           # SwiftUI @main entry point
|   +-- AppDelegate.swift          # NSStatusItem, NSPopover, fail-safes, SMAppService
|-- Core/
|   |-- HID/
|   |   |-- HIDDeviceModel.swift   # Codable mouse model & VID/PID identity
|   |   +-- DeviceMonitor.swift    # IOHIDManager matching, whitelist & activity tracking
|   |-- EventTap/
|   |   |-- TrackpadBlocker.swift  # CGEventTap interception & gesture filtering
|   |   +-- HotkeyManager.swift    # Carbon RegisterEventHotKey global shortcut
|   +-- Permissions/
|       +-- PermissionManager.swift  # Accessibility & Input Monitoring checks
|-- UI/
|   |-- MenuBarPopoverView.swift   # Main popover UI
|   |-- DeviceRowView.swift        # Whitelist row per detected mouse
|   |-- ShortcutRecorderView.swift # Interactive global shortcut recorder
|   +-- PermissionBannerView.swift # Permission onboarding banner
+-- Resources/
    |-- Info.plist                 # LSUIElement = true
    +-- MutePad.entitlements       # App Sandbox disabled for CGEventTap
```

---

## Roadmap

- [ ] Per-display / clamshell mode awareness
- [ ] Optional HUD toast notification when toggling via global shortcut
- [ ] Notarized releases via Apple Developer ID
- [ ] Localization (Indonesian & English)

---

## Support

If **MutePad** saves you from accidental palm clicks and cursor jumps, consider supporting its development:

[![Buy Me a Coffee (PayPal)](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/FRprojet)

---

## License

Released under the [MIT License](LICENSE).
