// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: SiteStore!
    private var loginWindow: LoginWindowController?
    private(set) var commander: CommanderWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // Test aid: write/read one Keychain item and quit (checks prompt-free access across builds).
        if let mode = value(after: "--keychain-selftest", in: args) {
            let store = KeychainSecretStore(service: Branding.bundleID + ".selftest")
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000D0C5")!
            if mode == "write" { try? store.setPassword("selftest-ok", for: id) }
            if mode == "delete" { try? store.setPassword(nil, for: id) }
            print("keychain-selftest \(mode): \(store.password(for: id) ?? "nil")")
            exit(0)
        }
        RemoteEditSession.removeStaleCopies()
        if !args.contains("--data-dir") && !args.contains("--snapshot") { LegacyMigration.run() }
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

        let support = SiteStore.defaultURL(appName: Branding.appName).deletingLastPathComponent()
        hostKeys = HostKeyStore(fileURL: dataDir.map { URL(fileURLWithPath: $0).appendingPathComponent("host_keys.json") }
                                ?? support.appendingPathComponent("host_keys.json"))
        prefs = PreferencesStore(fileURL: dataDir.map { URL(fileURLWithPath: $0).appendingPathComponent("preferences.json") }
                                 ?? support.appendingPathComponent("preferences.json"))
        applyTheme()
        Theme.startObserving()
        if let forced = value(after: "--appearance", in: args) { // snapshot testing
            NSApp.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua)
        }
        NotificationCenter.default.addObserver(forName: PreferencesStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
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

        if args.contains("--demo-screenshot") { DemoScene.build(app: self) }

        if args.contains("--demo-commander") {
            // Development aid: a Commander tab whose "remote" side is the local disk.
            let demoPath = value(after: "--demo-path", in: args) ?? ""
            let site = Site(path: "Demo", hostName: "localhost", userName: NSUserName(), remoteDirectory: demoPath, localDirectory: demoPath)
            attach(RemoteSession(site: site, fs: LocalFileSystem()) { LocalFileSystem() })
            if let tab = commander?.current {
                // Show the queue with one finished demo transfer.
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("duckscp-demo-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let file = tmp.appendingPathComponent("demo.bin")
                try? Data(count: 300_000).write(to: file)
                let out = tmp.appendingPathComponent("out")
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                tab.queue.add(TransferQueue.Item(upload: [file], to: out.path))
                commander?.transfers.setQueueVisible(true)
                if args.contains("--demo-sync") { commander?.toggleSynchronizedBrowsing() }
                if let name = value(after: "--demo-enter", in: args) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tab.local.load(RemotePath.join(tab.local.path, name)) }
                }
                // Development aid: start Keep Up to Date from the demo folder into another folder.
                if let target = value(after: "--demo-keep", in: args), let c = commander {
                    c.keepUpToDate()
                    c.debugStartKeepUpToDate(remote: target)
                }
            }
        }

        if let path = value(after: "--select-site", in: args), let site = store.sites.first(where: { $0.path == path }) {
            loginWindow?.reloadTree(select: site.id)
        }

        // Update check at launch (never in test/snapshot runs unless a test server is given).
        if prefs.current.checkForUpdatesAtLaunch && !isSnapshotMode && (dataDir == nil || args.contains("--update-api")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { UpdateController.shared.check(userInitiated: false) }
        }

        if args.contains("--show-preferences") {
            if isSnapshotMode { loginWindow?.window?.orderOut(nil) } // one window per screenshot
            showPreferences()
            if let tab = value(after: "--show-preferences", in: args), let i = Int(tab) { preferencesWindow?.selectTab(i) }
        }

        if let snapshotDir {
            let delay = value(after: "--snapshot-delay", in: args).flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.3) {
                // Screenshots should show the window as active (key window, accent selection).
                NSApp.activate(ignoringOtherApps: true)
                SnapshotWindow.forceActiveAppearance = true
                NSApp.windows.forEach { $0.contentView?.superview?.needsDisplay = true; $0.contentView?.needsDisplay = true }
                self.commander?.tabs.forEach { $0.local.refreshSelectionLook(); $0.remote.refreshSelectionLook() }
                (self.commander?.window ?? NSApp.windows.first { $0.isVisible })?.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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
            lw.onLoginWorkspace = { [weak self] ws in self?.openWorkspace(ws) }
            loginWindow = lw
        }
        loginWindow?.showWindow(nil)
    }

    private(set) var hostKeys: HostKeyStore!
    private(set) var prefs: PreferencesStore!
    /// --snapshot runs must never block on a dialog.
    var isSnapshotMode: Bool { CommandLine.arguments.contains("--snapshot") }

    static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(Branding.appName)/session.log")
    }

    static func logURL(_ p: Preferences) -> URL {
        p.logPath.isEmpty ? defaultLogURL : URL(fileURLWithPath: (p.logPath as NSString).expandingTildeInPath)
    }

    private var sessionLog: SessionLog?
    private var sessionLogURL: URL?

    /// Connection settings from Preferences → Network / Logging.
    func connectionSettings() -> ConnectionSettings {
        let p = prefs.current
        var log: SessionLog?
        if p.loggingEnabled {
            let url = Self.logURL(p)
            if sessionLogURL != url {
                sessionLog = try? SessionLog(url: url)
                sessionLogURL = url
            }
            log = sessionLog
        }
        return ConnectionSettings(p, log: log)
    }

    private var preferencesWindow: PreferencesWindowController?

    @objc func checkForUpdates() { UpdateController.shared.check(userInitiated: true) }

    @objc func showPreferences() {
        if preferencesWindow == nil { preferencesWindow = PreferencesWindowController(store: prefs, hostKeys: hostKeys) }
        preferencesWindow?.showWindow(nil)
    }

    @objc func toggleHiddenFiles() {
        try? prefs.update { $0.showHiddenFiles.toggle() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isSnapshotMode, prefs.current.confirmExitWithTransfers, commander?.tabs.contains(where: { $0.queue.hasActiveItems }) == true else {
            return .terminateNow
        }
        let a = NSAlert()
        a.messageText = "Transfers are still running. Quit anyway?"
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// System = follow macOS light/dark automatically.
    func applyTheme() {
        switch prefs.current.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    private var connecting: [ConnectingWindow] = []
    /// Passwords used by open sessions (memory only), so Save Workspace can store them.
    var passwordsForWorkspace: [UUID: String] = [:]

    /// Connects in the background behind WinSCP's progress dialog, then opens a tab.
    func openSession(_ site: Site, password: String?) {
        let dialog = ConnectingWindow(site: site)
        connecting.append(dialog)
        dialog.showWindow(nil)
        let hostKeys = self.hostKeys!
        var settings = connectionSettings()
        if site.proxy.isEnabled, !site.proxy.user.isEmpty { settings.proxyPassword = store.secrets.password(for: site.proxy.secretID) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<RemoteSession, Error> {
                let fs = try Connector.connect(site: site, password: password, prompter: dialog, hostKeys: hostKeys, settings: settings)
                if dialog.isCancelled { fs.close(); throw FileSystemError.cancelled }
                let cached = dialog.cached
                if cached.password == nil { cached.password = password }
                return RemoteSession(site: site, fs: fs) {
                    try Connector.connect(site: site, password: cached.password, prompter: cached, hostKeys: hostKeys, settings: settings)
                }
            }
            DispatchQueue.main.async { [self] in
                dialog.close()
                connecting.removeAll { $0 === dialog }
                switch result {
                case .success(let session):
                    passwordsForWorkspace[site.id] = dialog.cached.password // main thread only
                    // Connected fine, so the import notes (⚠︎) have served their purpose.
                    if store.site(site.id)?.importWarnings.isEmpty == false {
                        try? store.clearWarnings(of: site.id)
                        loginWindow?.siteChangedElsewhere(site.id)
                    }
                    attach(session)
                    // Test aid: navigate the remote panel, as a user would.
                    if let target = value(after: "--test-navigate", in: CommandLine.arguments), let tab = commander?.current {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { tab.remote.load(target) }
                    }
                    // Test aid: start editing a remote file, as F4 would (editor not launched in snapshot runs).
                    if let name = value(after: "--demo-edit", in: CommandLine.arguments), let tab = commander?.current {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                            if let e = tab.remote.entries.first(where: { $0.name == name }) {
                                commander?.transfers.editRemote(e, in: tab.remote, useEditor: true)
                            }
                        }
                    }
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

    func openWorkspace(_ ws: Workspace) {
        for site in ws.sites {
            openSession(site, password: site.hasStoredPassword ? store.secrets.password(for: site.id) : nil)
        }
    }

    /// Session → Save Workspace: stores the open tabs with their current folders.
    @objc func saveWorkspace() {
        guard let c = commander, !c.tabs.isEmpty else { return NSSound.beep() }
        let a = NSAlert()
        a.messageText = "Save workspace"
        a.informativeText = "Saves the \(c.tabs.count) open session(s) with their current folders."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "My Workspace"
        let savePasswords = NSButton(checkboxWithTitle: "Save passwords (Keychain)", target: nil, action: nil)
        savePasswords.state = .on
        let stack = NSStackView(views: [field, savePasswords])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 50)
        a.accessoryView = stack
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        var passwords: [UUID: String] = [:]
        let sites: [Site] = c.tabs.map { tab in
            var s = tab.session.site
            let originalID = s.id
            s.id = UUID()
            s.remoteDirectory = tab.remote.path
            s.localDirectory = tab.local.path
            if savePasswords.state == .on, let pw = tab.cachedPassword ?? store.secrets.password(for: originalID) { passwords[s.id] = pw }
            return s
        }
        do {
            try store.saveWorkspace(Workspace(name: field.stringValue, sites: sites), passwords: passwords)
            loginWindow?.reloadTree(select: nil)
        } catch {
            showError(error, in: c.window)
        }
    }

    /// Adds a connected session as a tab, creating the Commander window on first use.
    func attach(_ session: RemoteSession, localBackend: PanelBackend = LocalBackend()) {
        if commander == nil {
            let c = CommanderWindowController()
            c.onNewSession = { [weak self] in self?.showLogin() }
            c.onRememberDirectories = { [weak self] id, remote, local in
                guard let self, (try? self.store.rememberDirectories(of: id, remote: remote, local: local)) == true else { return }
                self.loginWindow?.siteChangedElsewhere(id)
            }
            commander = c
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
                self?.commander = nil
            }
        }
        commander?.add(session: session, localBackend: localBackend)
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
        // Panel paths, for scripted checks.
        for tab in app.commander?.tabs ?? [] { print("panels: local=\(tab.local.path) remote=\(tab.remote.path)") }
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            window.writeSnapshot(to: dir.appendingPathComponent("window-\(i).png"))
        }
        NSApp.terminate(nil)
    }
}
