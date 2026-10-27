// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// The app's accent colour: the macOS accent (System Settings → Appearance), blue when
/// none is set ("Multicolor") or it cannot be read, or a custom colour from Preferences.
/// Views observe `Theme.didChange` to repaint when either source changes.
enum Theme {
    static let didChange = Notification.Name("ThemeDidChange")
    static let fallback = NSColor.systemBlue

    static var accent: NSColor {
        let p = currentPrefs
        if p.accentMode == .custom, let c = NSColor(hex: p.customAccentHex) { return c }
        // No AppleAccentColor key = Multicolor: apps pick their own; ours is blue.
        guard UserDefaults.standard.object(forKey: "AppleAccentColor") != nil else { return fallback }
        return NSColor.controlAccentColor
    }

    /// Selection tint for inactive panels.
    static var accentSoft: NSColor { accent.withAlphaComponent(0.18) }

    /// Re-broadcasts system accent changes and preference changes as one notification.
    static func startObserving() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            center.post(name: didChange, object: nil)
        }
        center.addObserver(forName: PreferencesStore.didChange, object: nil, queue: .main) { _ in
            center.post(name: didChange, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleColorPreferencesChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            center.post(name: didChange, object: nil)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
