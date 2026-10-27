// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// Everything brand-specific is read from Info.plist, which scripts/build_app.sh
/// fills from branding.env. Rebranding = edit branding.env and rebuild.
/// Current preferences (defaults before the app finished launching).
var currentPrefs: Preferences {
    (NSApp?.delegate as? AppDelegate)?.prefs?.current ?? Preferences()
}

enum Branding {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DuckSCP"
    }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.duckscp" }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
