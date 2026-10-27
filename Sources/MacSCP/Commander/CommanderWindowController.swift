import AppKit
import SCPCore

/// One connected session inside the Commander window (a WinSCP tab).
final class SessionTab {
    let session: RemoteSession
    let local: FilePanel
    let remote: FilePanel
    var lastActive: FilePanel

    init(session: RemoteSession) {
        self.session = session
        local = FilePanel(backend: LocalBackend(), path: session.site.localDirectory.isEmpty ? nil : session.site.localDirectory)
        remote = FilePanel(backend: RemoteBackend(session: session),
                           path: session.site.remoteDirectory.isEmpty ? nil : session.site.remoteDirectory)
        lastActive = remote
    }

    var title: String { session.site.path.isEmpty ? session.site.displayTarget : session.site.name }
}

/// WinSCP's "Commander" interface: toolbar, session tabs, local and remote panels,
/// queue, F-key command bar and status bar.
final class CommanderWindowController: NSWindowController, NSWindowDelegate, FilePanelDelegate, NSToolbarDelegate {
    private(set) var tabs: [SessionTab] = []
    private(set) var current: SessionTab?
    var onNewSession: (() -> Void)?
    var transfers: TransferController!

    private let tabBar = NSStackView()
    private let split = NSSplitView()
    private let statusBytes = label("")
    private let statusProtocol = label("")
    private let statusTime = label("")
    private var timer: Timer?
    let queueContainer = NSView()
    var queueHeight: NSLayoutConstraint!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 420)
        window.setFrameAutosaveName("Commander")
        super.init(window: window)
        window.delegate = self
        transfers = TransferController(commander: self)
        buildUI()
        updateTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatusBar() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        let toolbar = NSToolbar(identifier: "Commander")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .expanded

        tabBar.orientation = .horizontal
        tabBar.spacing = 0
        tabBar.alignment = .bottom
        tabBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 0, right: 6)
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        queueContainer.translatesAutoresizingMaskIntoConstraints = false
        queueHeight = queueContainer.heightAnchor.constraint(equalToConstant: 0)
        queueHeight.isActive = true

        let fkeys = NSStackView(views: [
            fkey("F2 Rename", #selector(cmdRename)), fkey("F4 Edit", #selector(cmdEdit)),
            fkey("F5 Copy", #selector(cmdCopy)), fkey("F6 Move", #selector(cmdMove)),
            fkey("F7 Create Directory", #selector(cmdMakeDir)), fkey("F8 Delete", #selector(cmdDelete)),
            fkey("F9 Properties", #selector(cmdProperties)), fkey("F10 Quit", #selector(NSApplication.terminate(_:))),
        ])
        fkeys.distribution = .fillEqually
        fkeys.spacing = 2
        fkeys.translatesAutoresizingMaskIntoConstraints = false

        [statusBytes, statusProtocol, statusTime].forEach { $0.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        let status = NSStackView(views: [statusBytes, NSView(), statusProtocol, separator(), statusTime])
        status.translatesAutoresizingMaskIntoConstraints = false
        status.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        [tabBar, split, queueContainer, fkeys, status].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            split.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            queueContainer.topAnchor.constraint(equalTo: split.bottomAnchor),
            queueContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            queueContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fkeys.topAnchor.constraint(equalTo: queueContainer.bottomAnchor, constant: 4),
            fkeys.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            fkeys.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            status.topAnchor.constraint(equalTo: fkeys.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func fkey(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if action == #selector(NSApplication.terminate(_:)) { b.target = nil }
        return b
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let newSession = NSToolbarItem.Identifier("newSession")
        static let disconnect = NSToolbarItem.Identifier("disconnect")
        static let queue = NSToolbarItem.Identifier("queue")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let sites = NSToolbarItem.Identifier("sites")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.newSession, ToolbarID.sites, ToolbarID.disconnect, .flexibleSpace, ToolbarID.refresh, ToolbarID.queue]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id {
        case ToolbarID.newSession: configure(item, "New Session", "plus.rectangle.on.rectangle", #selector(newSession))
        case ToolbarID.sites: configure(item, "Sites", "list.bullet.rectangle", #selector(newSession))
        case ToolbarID.disconnect: configure(item, "Disconnect", "xmark.circle", #selector(disconnect))
        case ToolbarID.refresh: configure(item, "Refresh", "arrow.clockwise", #selector(refreshAll))
        case ToolbarID.queue: configure(item, "Queue", "list.number", #selector(toggleQueue))
        default: return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, _ label: String, _ symbol: String, _ action: Selector) {
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
    }

    // MARK: Tabs

    func add(session: RemoteSession) {
        let tab = SessionTab(session: session)
        tab.local.delegate = self
        tab.remote.delegate = self
        tab.local.onDrop = { [weak self] target, paths, from in self?.dropped(paths, on: target, from: from) }
        tab.remote.onDrop = { [weak self] target, paths, from in self?.dropped(paths, on: target, from: from) }
        tabs.append(tab)
        select(tab)
    }

    func select(_ tab: SessionTab) {
        current = tab
        split.arrangedSubviews.forEach { $0.removeFromSuperview() }
        split.addArrangedSubview(tab.local.view)
        split.addArrangedSubview(tab.remote.view)
        window?.contentView?.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        rebuildTabBar()
        tab.lastActive.focus()
        panelDidBecomeActive(tab.lastActive)
        updateTitle()
        updateStatusBar()
    }

    private func rebuildTabBar() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, tab) in tabs.enumerated() {
            let b = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            b.tag = i
            b.bezelStyle = .smallSquare
            b.setButtonType(.pushOnPushOff)
            b.state = tab === current ? .on : .off
            b.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            if let c = tab.session.site.color { b.contentTintColor = NSColor(winscpColor: c) }
            b.toolTip = "\(tab.session.site.displayTarget) (\(tab.session.fs.protocolName))"
            tabBar.addArrangedSubview(b)
        }
        let plus = NSButton(title: "New Tab", target: self, action: #selector(newSession))
        plus.bezelStyle = .smallSquare
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        plus.imagePosition = .imageLeading
        tabBar.addArrangedSubview(plus)
        tabBar.addArrangedSubview(NSView())
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        select(tabs[sender.tag])
    }

    @objc func newSession() { onNewSession?() }

    @objc func disconnect() {
        guard let tab = current, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.session.close()
        tabs.remove(at: i)
        if let next = tabs.last {
            select(next)
        } else {
            window?.close()
        }
    }

    @objc func refreshAll() {
        current?.local.refresh()
        current?.remote.refresh()
    }

    @objc func toggleQueue() { transfers.toggleQueueVisible() }

    // MARK: Panel delegate

    var activePanel: FilePanel? { current?.lastActive }

    func otherPanel(_ p: FilePanel) -> FilePanel? {
        guard let tab = current else { return nil }
        return p === tab.local ? tab.remote : tab.local
    }

    func panelDidBecomeActive(_ panel: FilePanel) {
        current?.lastActive = panel
        current?.local.setActive(panel === current?.local)
        current?.remote.setActive(panel === current?.remote)
    }

    func panelPathDidChange(_ panel: FilePanel) { updateTitle() }

    func panel(_ panel: FilePanel, didFail error: Error) { showError(error, in: window) }

    func panel(_ panel: FilePanel, command: PanelCommand) {
        panelDidBecomeActive(panel)
        switch command {
        case .copy: cmdCopy()
        case .move: cmdMove()
        case .delete: cmdDelete()
        case .rename: cmdRename()
        case .makeDirectory: cmdMakeDir()
        case .properties: cmdProperties()
        case .edit: cmdEdit()
        case .open: openFile(panel)
        case .switchPanel: otherPanel(panel)?.focus()
        }
    }

    // MARK: Commands

    /// Runs file-system work for a panel: local work on a background queue,
    /// remote work on the session queue. Completion arrives on main.
    func run<T>(on panel: FilePanel, _ work: @escaping (RemoteFileSystem) throws -> T,
                completion: @escaping (Result<T, Error>) -> Void) {
        if let remote = panel.backend as? RemoteBackend {
            remote.session.perform(work, completion: completion)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try work(LocalFileSystem()) }
                DispatchQueue.main.async { completion(r) }
            }
        }
    }

    @objc func cmdCopy() { startTransfer(move: false) }
    @objc func cmdMove() { startTransfer(move: true) }

    private func startTransfer(move: Bool) {
        guard let src = activePanel, let dst = otherPanel(src), !src.selectedEntries.isEmpty else { return NSSound.beep() }
        transfers.confirmAndQueue(entries: src.selectedEntries, from: src, to: dst, move: move)
    }

    private func dropped(_ paths: [String], on target: FilePanel, from source: FilePanel?) {
        if let source {
            let wanted = Set(paths)
            let entries = source.entries.filter { wanted.contains(RemotePath.join(source.path, $0.name)) }
            transfers.confirmAndQueue(entries: entries, from: source, to: target, move: false)
        } else if !target.backend.isLocal {
            // Files dragged in from Finder.
            transfers.uploadFromFinder(paths, to: target)
        }
    }

    @objc func cmdMakeDir() {
        guard let panel = activePanel else { return }
        prompt(title: "Create folder", message: "New folder name:", value: "New folder") { [self] name in
            guard RemotePath.isSafeName(name) else { return showError(FileSystemError(.other, "Invalid folder name."), in: window) }
            run(on: panel, { try $0.makeDirectory(RemotePath.join(panel.path, name)) }) { [self] r in
                if case .failure(let e) = r { showError(e, in: window) }
                panel.load(panel.path, recordHistory: false, select: name)
            }
        }
    }

    @objc func cmdRename() {
        guard let panel = activePanel, let e = panel.selectedEntries.first, panel.selectedEntries.count == 1 else { return NSSound.beep() }
        prompt(title: "Rename", message: "New name for \"\(e.name)\":", value: e.name) { [self] name in
            guard name != e.name else { return }
            guard RemotePath.isSafeName(name) else { return showError(FileSystemError(.other, "Invalid name."), in: window) }
            run(on: panel, { try $0.rename(RemotePath.join(panel.path, e.name), to: RemotePath.join(panel.path, name)) }) { [self] r in
                if case .failure(let err) = r { showError(err, in: window) }
                panel.load(panel.path, recordHistory: false, select: name)
            }
        }
    }

    @objc func cmdDelete() {
        guard let panel = activePanel, !panel.selectedEntries.isEmpty else { return NSSound.beep() }
        let entries = panel.selectedEntries
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Delete \"\(entries[0].name)\"?" : "Delete \(entries.count) files?"
        if panel.backend.isLocal {
            alert.informativeText = "Items are moved to the Trash."
        } else {
            alert.informativeText = "This cannot be undone."
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [self] r in
            guard r == .alertFirstButtonReturn else { return }
            let paths = entries.map { RemotePath.join(panel.path, $0.name) }
            if panel.backend.isLocal {
                do {
                    for p in paths { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
                } catch {
                    showError(error, in: window)
                }
                panel.refresh()
            } else {
                run(on: panel, { fs in
                    for (p, e) in zip(paths, entries) { try RecursiveOps.delete(p, entry: e, fs: fs) }
                }) { [self] r in
                    if case .failure(let err) = r { showError(err, in: window) }
                    panel.refresh()
                }
            }
        }
    }

    @objc func cmdProperties() {
        guard let panel = activePanel, let e = panel.selectedEntries.first else { return NSSound.beep() }
        let sheet = PropertiesSheet(entry: e, location: panel.path)
        sheet.onApply = { [self] mode in
            run(on: panel, { try $0.setPermissions(RemotePath.join(panel.path, e.name), mode) }) { [self] r in
                if case .failure(let err) = r { showError(err, in: window) }
                panel.refresh()
            }
        }
        propertiesSheet = sheet
        window?.beginSheet(sheet.window!)
    }
    private var propertiesSheet: PropertiesSheet?

    @objc func cmdEdit() {
        guard let panel = activePanel, let e = panel.selectedEntries.first, !e.isDirectoryLike else { return NSSound.beep() }
        if panel.backend.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: RemotePath.join(panel.path, e.name)))
        } else {
            transfers.editRemote(e, in: panel)
        }
    }

    private func openFile(_ panel: FilePanel) {
        guard let e = panel.selectedEntries.first else { return }
        if panel.backend.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: RemotePath.join(panel.path, e.name)))
        } else {
            transfers.editRemote(e, in: panel)
        }
    }

    func prompt(title: String, message: String, value: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { r in
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if r == .alertFirstButtonReturn, !v.isEmpty { completion(v) }
        }
    }

    // MARK: Title and status

    private func updateTitle() {
        guard let tab = current else {
            window?.title = Branding.appName
            return
        }
        // WinSCP: "path - user@host - AppName"
        window?.title = "\(RemotePath.name(tab.remote.path).isEmpty ? "/" : RemotePath.name(tab.remote.path)) - \(tab.session.site.displayTarget) - \(Branding.appName)"
    }

    func updateStatusBar() {
        guard let tab = current else { return }
        statusBytes.stringValue = transfers.statusText
        statusProtocol.stringValue = "🔒 \(tab.session.fs.protocolName)"
        statusTime.stringValue = Format.duration(Date().timeIntervalSince(tab.session.connectedAt))
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        tabs.forEach { $0.session.close() }
        tabs.removeAll()
    }

    // MARK: Keyboard (F-keys work through the Files menu key equivalents)

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        current != nil
    }
}
