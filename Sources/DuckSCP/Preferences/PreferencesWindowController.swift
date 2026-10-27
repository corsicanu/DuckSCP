// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// WinSCP's Preferences dialog, one tab per section. Every control writes straight
/// to the PreferencesStore (macOS style: no OK/Cancel).
final class PreferencesWindowController: NSWindowController {
    private let store: PreferencesStore
    private let hostKeys: HostKeyStore
    private var refreshers: [() -> Void] = []
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    init(store: PreferencesStore, hostKeys: HostKeyStore) {
        self.store = store
        self.hostKeys = hostKeys
        let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferences"
        super.init(window: window)

        // Toolbar-style sections, the macOS equivalent of WinSCP's section tree.
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let icons = ["Environment": "macwindow", "Confirmations": "checkmark.circle", "Panels": "sidebar.left",
                     "Editors": "pencil", "Transfer": "arrow.up.arrow.down", "Endurance": "arrow.clockwise",
                     "Network": "network", "Logging": "doc.text", "Security": "lock"]
        for (title, rows) in sections() {
            let vc = NSViewController()
            vc.view = page(rows)
            vc.view.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: icons[title] ?? "gear", accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: 760, height: 320))
        window.center()
        NotificationCenter.default.addObserver(forName: PreferencesStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.refreshers.forEach { $0() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func selectTab(_ index: Int) {
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = index
    }

    // MARK: Sections

    private func sections() -> [(String, [[NSView]])] {
        [
            ("Environment", [
                popup("Theme:", [("Follow system", Preferences.Theme.system), ("Light", .light), ("Dark", .dark)], \.theme),
                popup("Interface:", [("Commander (two panels)", Preferences.Interface.commander),
                                     ("Explorer (remote panel only)", .explorer)], \.interface),
                popup("Accent color:", [("Follow macOS (blue if none set)", Preferences.AccentMode.system),
                                        ("Custom", .custom)], \.accentMode),
                [label("Custom color:"), accentWell()],
            ]),
            ("Confirmations", [
                check("Confirm deleting files", \.confirmDelete),
                check("Confirm overwriting files", \.confirmOverwrite),
                check("Confirm quitting while transfers are queued", \.confirmExitWithTransfers),
                check("Confirm closing a session", \.confirmDisconnect),
            ]),
            ("Panels", [
                check("Show hidden files (⇧⌘.)", \.showHiddenFiles),
                popup("Size format:", [("Bytes (1,234,567)", Preferences.SizeFormat.bytes), ("Kilobytes (1,206 KB)", .kilobytes),
                                       ("Short (1.2 MB)", .short)], \.sizeFormat),
                popup("Double-click on a file:", [("Open (default app)", Preferences.DoubleClickAction.open),
                                                  ("Edit (text editor)", .edit), ("Copy to other panel", .copy)], \.doubleClickAction),
                check("Move deleted local files to the Trash", \.useTrashForLocalDelete),
                check("Synchronized browsing", \.synchronizedBrowsing),
                [NSView(), note("Folders are always listed before files.")],
            ]),
            ("Editors", [
                [label("Editor:"), editorStatus()],
                text("Custom editor app:", \.customEditorPath, placeholder: "/Applications/…app (empty = Sublime Text, then TextEdit)"),
                [NSView(), actionButton("Choose…") { [weak self] in self?.chooseEditor() }],
                [NSView(), note("F4 / Edit opens files in this editor. Remote files are uploaded back on every save.")],
            ]),
            ("Transfer", [
                check("Preserve timestamp", \.preserveTimestamp),
                check("Set permissions from local files when uploading", \.preservePermissions),
                check("Enable transfer resume / temporary .filepart files", \.resumeEnabled),
                number("Resume threshold (KB):", \.resumeThresholdKB),
                number("Speed limit (KB/s, 0 = unlimited):", \.speedLimitKBps),
                text("Exclude mask:", \.excludeMask, placeholder: "*.tmp; .git/; Thumbs.db"),
                check("Transfer in background by default", \.transferInBackgroundByDefault),
            ]),
            ("Endurance", [
                check("Automatically reconnect after a connection is lost", \.autoReconnect),
                number("Reconnect attempts:", \.reconnectAttempts),
                number("Delay between attempts (s):", \.reconnectDelaySeconds),
            ]),
            ("Network", [
                number("Connection timeout (s):", \.connectTimeoutSeconds),
                number("Keepalive interval (s, 0 = off):", \.keepaliveSeconds),
                popup("IP version:", [("Auto", Preferences.IPVersion.auto), ("IPv4", .ipv4), ("IPv6", .ipv6)], \.ipVersion),
            ]),
            ("Logging", [
                check("Enable session logging", \.loggingEnabled),
                text("Log file:", \.logPath, placeholder: AppDelegate.defaultLogURL.path),
                [NSView(), actionButton("Show Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.logURL(self.store.current)])
                }],
                [NSView(), note("Logs contain host names, paths and errors, never passwords.")],
            ]),
            ("Security", [
                [label("Passwords:"), note("Stored in the macOS Keychain (this device only).")],
                [label("Host keys:"), actionButton("Clear Cached Host Keys…") { [weak self] in self?.clearHostKeys() }],
            ]),
        ]
    }

    // MARK: Row builders

    private func update(_ change: (inout Preferences) -> Void) {
        do { try store.update(change) } catch { showError(error, in: window) }
    }

    private func check(_ title: String, _ kp: WritableKeyPath<Preferences, Bool>) -> [NSView] {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        bindAction(b) { [weak self, weak b] in self?.update { $0[keyPath: kp] = b?.state == .on } }
        refreshers.append { [weak self, weak b] in b?.state = self?.store.current[keyPath: kp] == true ? .on : .off }
        refreshers.last?()
        return [NSView(), b]
    }

    private func popup<T: Equatable>(_ title: String, _ options: [(String, T)], _ kp: WritableKeyPath<Preferences, T>) -> [NSView] {
        let p = NSPopUpButton()
        options.forEach { p.addItem(withTitle: $0.0) }
        bindAction(p) { [weak self, weak p] in
            guard let i = p?.indexOfSelectedItem, i >= 0 else { return }
            self?.update { $0[keyPath: kp] = options[i].1 }
        }
        refreshers.append { [weak self, weak p] in
            guard let self else { return }
            p?.selectItem(at: options.firstIndex { $0.1 == self.store.current[keyPath: kp] } ?? 0)
        }
        refreshers.last?()
        return [label(title), p]
    }

    private func number(_ title: String, _ kp: WritableKeyPath<Preferences, Int>) -> [NSView] {
        let f = DuckSCP.textField(80)
        f.formatter = { let n = NumberFormatter(); n.minimum = 0; n.maximum = 1_000_000; n.allowsFloats = false; return n }()
        bindAction(f) { [weak self, weak f] in self?.update { $0[keyPath: kp] = f?.integerValue ?? 0 } }
        refreshers.append { [weak self, weak f] in f?.integerValue = self?.store.current[keyPath: kp] ?? 0 }
        refreshers.last?()
        return [label(title), f]
    }

    private func text(_ title: String, _ kp: WritableKeyPath<Preferences, String>, placeholder: String) -> [NSView] {
        let f = DuckSCP.textField(340)
        f.placeholderString = placeholder
        bindAction(f) { [weak self, weak f] in self?.update { $0[keyPath: kp] = f?.stringValue ?? "" } }
        refreshers.append { [weak self, weak f] in f?.stringValue = self?.store.current[keyPath: kp] ?? "" }
        refreshers.last?()
        return [label(title), f]
    }

    /// Swatch that opens the macOS colour panel; picking a colour switches to Custom.
    private func accentWell() -> NSView {
        let swatch = ColorSwatchButton()
        swatch.onChange = { [weak self] color in
            self?.update { $0.customAccentHex = color.hexString; $0.accentMode = .custom }
        }
        let reset = actionButton("Use macOS Accent") { [weak self] in self?.update { $0.accentMode = .system } }
        refreshers.append { [weak self, weak swatch] in
            guard let self else { return }
            swatch?.color = NSColor(hex: self.store.current.customAccentHex) ?? Theme.fallback
            reset.isEnabled = self.store.current.accentMode == .custom
        }
        refreshers.last?()
        return NSStackView(views: [swatch, reset])
    }

    private func note(_ text: String) -> NSTextField {
        let l = label(text)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return l
    }

    private func editorStatus() -> NSTextField {
        let l = label("")
        refreshers.append { [weak self, weak l] in
            guard let self else { return }
            l?.stringValue = EditorLauncher.editorName(self.store.current)
        }
        refreshers.last?()
        return l
    }

    private func actionButton(_ title: String, _ run: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        bindAction(b, run)
        return b
    }

    private func bindAction(_ control: NSControl, _ run: @escaping () -> Void) {
        actions[ObjectIdentifier(control)] = run
        control.target = self
        control.action = #selector(controlChanged(_:))
    }

    @objc private func controlChanged(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }

    private func page(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        let v = NSView()
        v.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
        ])
        return v
    }

    // MARK: Actions

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url { update { $0.customEditorPath = url.path } }
    }

    private func clearHostKeys() {
        let a = NSAlert()
        a.messageText = "Forget all cached host keys?"
        a.informativeText = "You will be asked to verify each server's key again on the next connection. ~/.ssh/known_hosts is not changed."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try hostKeys.clearAll() } catch { showError(error, in: window) }
    }
}
