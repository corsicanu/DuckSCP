import AppKit
import SCPCore

/// Opens files in the preferred text editor: custom app, else the first installed
/// of the configured bundle ids (Sublime Text 4/3/2), else TextEdit.
enum EditorLauncher {
    static func editorURL(_ prefs: Preferences) -> URL? {
        if !prefs.customEditorPath.isEmpty, FileManager.default.fileExists(atPath: prefs.customEditorPath) {
            return URL(fileURLWithPath: prefs.customEditorPath)
        }
        for id in prefs.editorBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
    }

    static func editorName(_ prefs: Preferences) -> String {
        editorURL(prefs).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "none"
    }

    static func edit(_ file: URL, prefs: Preferences) {
        guard let app = editorURL(prefs) else {
            NSWorkspace.shared.open(file)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config) { _, error in
            // Fall back to the system default app if the editor refuses the file.
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(file) } }
        }
    }
}
