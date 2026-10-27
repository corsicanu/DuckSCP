import AppKit
import SCPCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: SiteStore!
    private var loginWindow: LoginWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let snapshotDir = value(after: "--snapshot", in: args)
        let dataDir = value(after: "--data-dir", in: args)

        // --data-dir and --snapshot use throwaway storage so tests never touch real sites or the Keychain.
        if let dataDir {
            store = SiteStore(fileURL: URL(fileURLWithPath: dataDir).appendingPathComponent("sites.json"), secrets: InMemorySecretStore())
        } else if snapshotDir != nil {
            NSApp.appearance = NSAppearance(named: .aqua) // PDF snapshots draw no window background
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = SiteStore(fileURL: tmp.appendingPathComponent("sites.json"), secrets: InMemorySecretStore())
        } else {
            store = SiteStore(fileURL: SiteStore.defaultURL(appName: Branding.appName),
                              secrets: KeychainSecretStore(service: Branding.bundleID + ".sites"))
        }

        NSApp.mainMenu = MainMenu.build()
        showLogin()
        if let ini = value(after: "--import", in: args) {
            loginWindow?.importIni(at: URL(fileURLWithPath: ini))
        }
        NSApp.activate(ignoringOtherApps: true)

        if let snapshotDir {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Snapshot.run(to: URL(fileURLWithPath: snapshotDir), app: self)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showLogin() {
        if loginWindow == nil {
            let lw = LoginWindowController(store: store)
            lw.onLogin = { [weak self] site, password in self?.openSession(site, password: password) }
            loginWindow = lw
        }
        loginWindow?.showWindow(nil)
    }

    func openSession(_ site: Site, password: String?) {
        let alert = NSAlert()
        alert.messageText = "Connecting to \(site.displayTarget) arrives in a later phase."
        alert.runModal()
    }

    var loginController: LoginWindowController? { loginWindow }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

enum Snapshot {
    /// Imports the sample ini, writes PNGs of the app windows, then quits.
    static func run(to dir: URL, app: AppDelegate) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            window.writeSnapshot(to: dir.appendingPathComponent("window-\(i).png"))
        }
        NSApp.terminate(nil)
    }
}
