import Foundation

/// Everything brand-specific is read from Info.plist, which scripts/build_app.sh
/// fills from branding.env. Rebranding = edit branding.env and rebuild.
enum Branding {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MacSCP"
    }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.macscp" }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
