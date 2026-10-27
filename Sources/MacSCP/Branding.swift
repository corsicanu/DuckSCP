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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MacSCP"
    }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.macscp" }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
