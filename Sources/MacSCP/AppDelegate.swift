import AppKit
import SCPCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: SiteStore!
    private var loginWindow: LoginWindowController?
    private(set) var commander: CommanderWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let snapshotDir = value(after: "--snapshot", in: args)
        let dataDir = value(after: "--data-dir", in: args)

        // --data-dir and --snapshot use throwaway storage so tests never touch real sites or the Keychain.
        if let dataDir {
            store = SiteStore(fileURL: URL(fileURLWithPath: dataDir).appendingPathComponent("sites.json"), secrets: InMemorySecretStore())
        } else if snapshotDir != nil {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = SiteStore(fileURL: tmp.appendingPathComponent("sites.json"), secrets: InMemorySecretStore())
        } else {
            store = SiteStore(fileURL: SiteStore.defaultURL(appName: Branding.appName),
                              secrets: KeychainSecretStore(service: Branding.bundleID + ".sites"))
        }

        if snapshotDir != nil { NSApp.appearance = NSAppearance(named: .aqua) } // PDF snapshots draw no window background
        let support = SiteStore.defaultURL(appName: Branding.appName).deletingLastPathComponent()
        hostKeys = HostKeyStore(fileURL: dataDir.map { URL(fileURLWithPath: $0).appendingPathComponent("host_keys.json") }
                                ?? support.appendingPathComponent("host_keys.json"))
        NSApp.mainMenu = MainMenu.build()
        showLogin()
        if let ini = value(after: "--import", in: args) {
            loginWindow?.importIni(at: URL(fileURLWithPath: ini))
        }
        NSApp.activate(ignoringOtherApps: true)

        // Like `winscp.exe "Site name"`: open a stored site straight away.
        if let name = value(after: "--open", in: args) {
            if let site = store.sites.first(where: { $0.path == name }) {
                openSession(site, password: site.hasStoredPassword ? store.secrets.password(for: site.id) : nil)
            } else {
                showError(FileSystemError(.notFound, "No site named \"\(name)\"."), in: nil)
            }
        }

        if args.contains("--demo-commander") {
            // Development aid: a Commander tab whose "remote" side is the local disk.
            let site = Site(path: "Demo", hostName: "localhost", userName: NSUserName())
            attach(RemoteSession(site: site, fs: LocalFileSystem()) { LocalFileSystem() })
            if let tab = commander?.current {
                // Show the queue with one finished demo transfer.
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-demo-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let file = tmp.appendingPathComponent("demo.bin")
                try? Data(count: 300_000).write(to: file)
                let out = tmp.appendingPathComponent("out")
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                tab.queue.add(TransferQueue.Item(upload: [file], to: out.path))
                commander?.transfers.setQueueVisible(true)
            }
        }

        if let snapshotDir {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Snapshot.run(to: URL(fileURLWithPath: snapshotDir), app: self)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        commander?.transfers.stopEditing()
    }

    // Files menu: forwards to the Commander's active panel.
    @objc func filesCommand(_ sender: NSMenuItem) {
        guard let c = commander else { return NSSound.beep() }
        switch sender.tag {
        case 2: c.cmdRename()
        case 4: c.cmdEdit()
        case 5: c.cmdCopy()
        case 6: c.cmdMove()
        case 7: c.cmdMakeDir()
        case 8: c.cmdDelete()
        case 9: c.cmdProperties()
        default: break
        }
    }

    @objc func showLogin() {
        if loginWindow == nil {
            let lw = LoginWindowController(store: store, hostKeys: hostKeys)
            lw.onLogin = { [weak self] site, password in self?.openSession(site, password: password) }
            loginWindow = lw
        }
        loginWindow?.showWindow(nil)
    }

    private(set) var hostKeys: HostKeyStore!
    private var connecting: [ConnectingWindow] = []

    /// Connects in the background behind WinSCP's progress dialog, then opens a tab.
    func openSession(_ site: Site, password: String?) {
        let dialog = ConnectingWindow(site: site)
        connecting.append(dialog)
        dialog.showWindow(nil)
        let hostKeys = self.hostKeys!
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<RemoteSession, Error> {
                let fs = try Connector.connect(site: site, password: password, prompter: dialog, hostKeys: hostKeys)
                if dialog.isCancelled { fs.close(); throw FileSystemError.cancelled }
                let cached = dialog.cached
                if cached.password == nil { cached.password = password }
                return RemoteSession(site: site, fs: fs) {
                    try Connector.connect(site: site, password: cached.password, prompter: cached, hostKeys: hostKeys)
                }
            }
            DispatchQueue.main.async { [self] in
                dialog.close()
                connecting.removeAll { $0 === dialog }
                switch result {
                case .success(let session):
                    attach(session)
                case .failure(let error):
                    if (error as? FileSystemError)?.code == .cancelled { return }
                    let a = NSAlert()
                    a.alertStyle = .critical
                    a.messageText = "Cannot connect to \(site.displayTarget)"
                    a.informativeText = String(describing: error)
                    a.runModal()
                    showLogin()
                }
            }
        }
    }

    /// Adds a connected session as a tab, creating the Commander window on first use.
    func attach(_ session: RemoteSession) {
        if commander == nil {
            let c = CommanderWindowController()
            c.onNewSession = { [weak self] in self?.showLogin() }
            commander = c
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
                self?.commander = nil
            }
        }
        commander?.add(session: session)
        commander?.showWindow(nil)
        loginWindow?.window?.orderOut(nil)
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
