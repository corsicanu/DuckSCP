// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// The WinSCP "Login" dialog: site tree on the left, session settings on the right.
final class LoginWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    private final class Node {
        enum Kind { case newSite, folder(String), site(UUID), workspace(UUID) }
        let kind: Kind
        let title: String
        var children: [Node] = []
        init(_ kind: Kind, _ title: String) { self.kind = kind; self.title = title }
    }

    let store: SiteStore
    let hostKeys: HostKeyStore
    /// Called with the edited (possibly unsaved) site and the password to use.
    var onLogin: ((Site, String?) -> Void)?
    /// Opens every session of a workspace.
    var onLoginWorkspace: ((Workspace) -> Void)?

    private var root: [Node] = []
    private var draft = Site(path: "")
    private var selectedID: UUID?

    private let outline = NSOutlineView()
    private let protocolPopup = NSPopUpButton()
    private let encryptionLabel = label("Encryption:")
    private let encryptionPopup = NSPopUpButton()
    private let hostField = textField()
    private let portField = textField(70)
    private let userField = textField()
    private let passwordField = NSSecureTextField()
    private let warningLabel = label("")
    private let saveButton = MenuButton(title: "Save", menu: NSMenu())

    init(store: SiteStore, hostKeys: HostKeyStore) {
        self.store = store
        self.hostKeys = hostKeys
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Login - \(Branding.appName)"
        window.minSize = NSSize(width: 600, height: 400)
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadTree(select: nil)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Site tree
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .small
        outline.target = self
        outline.doubleAction = #selector(login)
        outline.menu = manageMenu()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tools = MenuButton(title: "Tools", menu: toolsMenu())
        let manage = MenuButton(title: "Manage", menu: manageMenu())

        // Session group
        for p in FileProtocol.allCases {
            protocolPopup.addItem(withTitle: p.title)
        }
        protocolPopup.autoenablesItems = false
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged)
        FtpEncryption.allCases.forEach { encryptionPopup.addItem(withTitle: $0.title) }
        encryptionPopup.target = self
        encryptionPopup.action = #selector(encryptionChanged)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 3
        warningLabel.preferredMaxLayoutWidth = 360

        saveButton.popupMenu.add("Save", #selector(save), target: self)
        saveButton.popupMenu.add("Save As…", #selector(saveAs), target: self)
        saveButton.popupMenu.add("Set Defaults", nil).isEnabled = false
        let advanced = button("Advanced…", self, #selector(showAdvanced))

        let protoRow = NSStackView(views: [vstack(label("File protocol:"), protocolPopup),
                                           vstack(encryptionLabel, encryptionPopup)])
        protoRow.distribution = .fillEqually
        let hostRow = NSStackView(views: [vstack(label("Host name:"), hostField), vstack(label("Port number:"), portField)])
        let userRow = NSStackView(views: [vstack(label("User name:"), userField), vstack(label("Password:"), passwordField)])
        userRow.distribution = .fillEqually
        let buttonRow = NSStackView(views: [saveButton, NSView(), advanced])

        let session = NSStackView(views: [protoRow, hostRow, userRow, buttonRow, warningLabel])
        session.orientation = .vertical
        session.alignment = .leading
        session.spacing = 12
        [protoRow, hostRow, userRow, buttonRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: session.widthAnchor).isActive = true
        }
        let box = NSBox()
        box.title = "Session"
        box.translatesAutoresizingMaskIntoConstraints = false
        let boxContent = NSView()
        boxContent.addSubview(session)
        box.contentView = boxContent
        session.translatesAutoresizingMaskIntoConstraints = false

        let loginButton = button("Login", self, #selector(login))
        loginButton.keyEquivalent = "\r"
        let close = button("Close", self, #selector(closeWindow))
        let help = button("Help", self, #selector(help))
        let bottom = NSStackView(views: [loginButton, close, help])
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let leftButtons = NSStackView(views: [tools, manage])
        leftButtons.translatesAutoresizingMaskIntoConstraints = false

        [scroll, box, bottom, leftButtons].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.widthAnchor.constraint(equalToConstant: 230),
            scroll.bottomAnchor.constraint(equalTo: leftButtons.topAnchor, constant: -10),
            leftButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            leftButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            box.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            session.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 10),
            session.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 10),
            session.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor, constant: -10),
            session.bottomAnchor.constraint(lessThanOrEqualTo: boxContent.bottomAnchor, constant: -10),
            box.bottomAnchor.constraint(lessThanOrEqualTo: bottom.topAnchor, constant: -10),

            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func vstack(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 3
        // Inputs stretch to the column width unless they have a fixed width (port field).
        for v in views where !(v is NSTextField && !(v as! NSTextField).isEditable) {
            if !v.constraints.contains(where: { $0.firstAttribute == .width }) {
                v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            }
        }
        return s
    }

    private func toolsMenu() -> NSMenu {
        let m = NSMenu()
        m.add("Import Sites from WinSCP.ini…", #selector(importIniFromPanel), target: self)
        m.addItem(.separator())
        m.add("Preferences…", #selector(AppDelegate.showPreferences))
        m.add("About \(Branding.appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        return m
    }

    private func manageMenu() -> NSMenu {
        let m = NSMenu()
        m.add("Login", #selector(login), target: self)
        m.addItem(.separator())
        m.add("Rename…", #selector(rename), target: self)
        m.add("Clone to New Site", #selector(clone), target: self)
        m.add("Delete", #selector(deleteSelected), target: self)
        m.add("Forget Password", #selector(forgetPassword), target: self)
        return m
    }

    // MARK: - Tree

    func reloadTree(select id: UUID?) {
        let newSite = Node(.newSite, "New Site")
        var folders: [String: Node] = [:]
        var top: [Node] = [newSite]
        func folderNode(_ comps: [String]) -> Node? {
            guard !comps.isEmpty else { return nil }
            let key = comps.joined(separator: "/")
            if let f = folders[key] { return f }
            let f = Node(.folder(key), comps.last!)
            folders[key] = f
            if let parent = folderNode(Array(comps.dropLast())) { parent.children.append(f) } else { top.append(f) }
            return f
        }
        for site in store.sites.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let n = Node(.site(site.id), site.name)
            if let parent = folderNode(site.folders) { parent.children.append(n) } else { top.append(n) }
        }
        func sortNodes(_ nodes: inout [Node]) {
            nodes.sort { a, b in
                switch (a.kind, b.kind) {
                case (.newSite, _): return true
                case (_, .newSite): return false
                case (.folder, .site): return true
                case (.site, .folder): return false
                default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
            for n in nodes { sortNodes(&n.children) }
        }
        sortNodes(&top)
        // Workspaces after the sites, like WinSCP's tree.
        top += store.workspaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { Node(.workspace($0.id), $0.name) }
        root = top
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        selectRow(for: id)
    }

    private func selectRow(for id: UUID?) {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? Node else { continue }
            let match: Bool
            switch node.kind {
            case .newSite: match = id == nil
            case .site(let sid): match = sid == id
            case .folder, .workspace: match = false
            }
            if match {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                break
            }
        }
        selectionChanged()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? root.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? root[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .folder = (item as! Node).kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        let cell = NSTableCellView()
        let image = NSImageView()
        let text = NSTextField(labelWithString: node.title)
        switch node.kind {
        case .newSite: image.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        case .workspace(let id):
            image.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            image.contentTintColor = .systemTeal
            text.toolTip = store.workspaces.first { $0.id == id }.map { $0.sites.map(\.displayTarget).joined(separator: "\n") }
        case .folder: image.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            image.contentTintColor = .systemYellow
        case .site(let id):
            let site = store.site(id)
            image.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            if let c = site?.color { image.contentTintColor = NSColor(winscpColor: c) }
            if site?.importWarnings.isEmpty == false { text.stringValue += " ⚠︎" }
        }
        cell.addSubview(image)
        cell.addSubview(text)
        cell.textField = text
        cell.imageView = image
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    private var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }

    private func selectionChanged() {
        switch selectedNode?.kind {
        case .site(let id)?:
            selectedID = id
            draft = store.site(id) ?? Site(path: "")
        case .folder(let path)?:
            selectedID = nil
            draft = Site(path: path + "/")
        case .workspace(let id)?:
            selectedID = nil
            let ws = store.workspaces.first { $0.id == id }
            draft = ws?.sites.first ?? Site(path: "")
            draft.importWarnings = ["Workspace: \(ws?.sites.count ?? 0) session(s): " + (ws?.sites.map(\.displayTarget).joined(separator: ", ") ?? "")]
        default:
            selectedID = nil
            draft = Site(path: "")
        }
        loadFields()
    }

    // MARK: - Fields

    private func loadFields() {
        protocolPopup.selectItem(at: FileProtocol.allCases.firstIndex(of: draft.fileProtocol) ?? 0)
        encryptionPopup.selectItem(at: FtpEncryption.allCases.firstIndex(of: draft.ftpEncryption) ?? 0)
        hostField.stringValue = draft.hostName
        portField.stringValue = String(draft.port)
        userField.stringValue = draft.userName
        passwordField.stringValue = ""
        passwordField.placeholderString = draft.hasStoredPassword ? "(saved in Keychain)" : nil
        warningLabel.stringValue = draft.importWarnings.joined(separator: "\n")
        updateEncryptionVisibility()
    }

    /// Copies the visible fields back into `draft`.
    private func readFields() {
        draft.fileProtocol = FileProtocol.allCases[max(0, protocolPopup.indexOfSelectedItem)]
        draft.ftpEncryption = FtpEncryption.allCases[max(0, encryptionPopup.indexOfSelectedItem)]
        draft.hostName = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.userName = userField.stringValue.trimmingCharacters(in: .whitespaces)
        if let p = Int(portField.stringValue), (1...65535).contains(p) { draft.port = p }
    }

    private func updateEncryptionVisibility() {
        let proto = FileProtocol.allCases[max(0, protocolPopup.indexOfSelectedItem)]
        encryptionLabel.isHidden = !proto.hasEncryptionChoice
        encryptionPopup.isHidden = !proto.hasEncryptionChoice
    }

    @objc private func protocolChanged() {
        let oldDefault = Site.defaultPort(draft.fileProtocol, draft.ftpEncryption)
        let oldProtocol = draft.fileProtocol
        readFields()
        // Like WinSCP: a new S3 session points at AWS over TLS.
        if draft.fileProtocol == .s3 && oldProtocol != .s3 {
            if draft.hostName.isEmpty { draft.hostName = "s3.amazonaws.com"; hostField.stringValue = draft.hostName }
            if draft.ftpEncryption == .none {
                draft.ftpEncryption = .implicitTLS
                encryptionPopup.selectItem(at: FtpEncryption.allCases.firstIndex(of: .implicitTLS) ?? 0)
            }
        }
        if Int(portField.stringValue) == oldDefault {
            draft.port = Site.defaultPort(draft.fileProtocol, draft.ftpEncryption)
            portField.stringValue = String(draft.port)
        }
        updateEncryptionVisibility()
    }

    @objc private func encryptionChanged() { protocolChanged() }

    // MARK: - Actions

    @objc func login() {
        if case .workspace(let id)? = selectedNode?.kind, let ws = store.workspaces.first(where: { $0.id == id }) {
            onLoginWorkspace?(ws)
            return
        }
        readFields()
        guard !draft.hostName.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(hostField)
            return
        }
        var password: String? = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        if password == nil, let id = selectedID, draft.hasStoredPassword {
            password = store.secrets.password(for: id)
        }
        onLogin?(draft, password)
    }

    @objc private func save() {
        readFields()
        if let id = selectedID, store.site(id) != nil {
            persist(draft, password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue)
        } else {
            saveAs()
        }
    }

    /// WinSCP's "Save session as site" dialog: name, folder and "Save password".
    @objc private func saveAs() {
        readFields()
        let alert = NSAlert()
        alert.messageText = "Save session as site"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let name = textField(300)
        let folderPrefix = draft.path.hasSuffix("/") ? draft.path : draft.folders.map { $0 + "/" }.joined()
        name.stringValue = folderPrefix + (draft.hostName.isEmpty ? "New Site" : draft.displayTarget)
        let savePassword = NSButton(checkboxWithTitle: "Save password (stored in the macOS Keychain)", target: nil, action: nil)
        savePassword.state = passwordField.stringValue.isEmpty ? .off : .on
        let stack = NSStackView(views: [label("Site name (use / for folders):"), name, savePassword])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 76)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window!) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let path = name.stringValue.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: "/")
            guard !path.isEmpty else { return }
            var site = draft
            site.id = UUID()
            site.path = store.uniquePath(path)
            site.importWarnings = []
            site.hasStoredPassword = false
            persist(site, password: savePassword.state == .on ? passwordField.stringValue : nil)
        }
    }

    private func persist(_ site: Site, password: String?) {
        do {
            try store.upsert(site, password: password)
            reloadTree(select: site.id)
        } catch {
            showError(error, in: window)
        }
    }

    @objc private func rename() {
        guard let id = selectedID, var site = store.site(id) else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Rename site"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = textField(300)
        field.stringValue = site.path
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.beginSheetModal(for: window!) { [self] r in
            guard r == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            site.path = store.uniquePath(field.stringValue, excluding: id)
            persist(site, password: nil)
        }
    }

    @objc private func clone() {
        guard let id = selectedID, var site = store.site(id) else { return NSSound.beep() }
        let pw = site.hasStoredPassword ? store.secrets.password(for: id) : nil
        site.id = UUID()
        site.path = store.uniquePath(site.path)
        site.hasStoredPassword = false
        persist(site, password: pw)
    }

    @objc private func deleteSelected() {
        let target: String
        let action: () throws -> Void
        switch selectedNode?.kind {
        case .site(let id)?:
            target = "site \"\(store.site(id)?.path ?? "")\""
            action = { try self.store.delete(id) }
        case .folder(let path)?:
            target = "folder \"\(path)\" and all its sites"
            action = { try self.store.deleteFolder(path) }
        case .workspace(let id)?:
            target = "workspace \"\(store.workspaces.first { $0.id == id }?.name ?? "")\""
            action = { try self.store.deleteWorkspace(id) }
        default:
            return NSSound.beep()
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(target)?"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [self] r in
            guard r == .alertFirstButtonReturn else { return }
            do { try action(); reloadTree(select: nil) } catch { showError(error, in: window) }
        }
    }

    @objc private func forgetPassword() {
        guard let id = selectedID, let site = store.site(id) else { return NSSound.beep() }
        persist(site, password: "")
    }

    @objc private func showAdvanced() {
        readFields()
        let sheet = AdvancedSiteSheet(site: draft, secrets: store.secrets)
        sheet.onDone = { [weak self] edited in
            guard let self else { return }
            self.draft = edited
        }
        window?.beginSheet(sheet.window!)
        advancedSheet = sheet
    }
    private var advancedSheet: AdvancedSiteSheet?

    @objc func importIniFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Sites from WinSCP.ini"
        panel.allowedContentTypes = [.init(filenameExtension: "ini") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window!) { [self] r in
            guard r == .OK, let url = panel.url else { return }
            importIni(at: url)
        }
    }

    func importIni(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var master: String?
            if WinSCPIniImporter.usesMasterPassword(data) {
                master = askMasterPassword(data)
            }
            let result = WinSCPIniImporter().importData(data, masterPassword: master)
            let count = try store.merge(result)
            let keyCount = hostKeys.importWinSCP(result.hostKeys)
            var prefsApplied: [String] = []
            if let prefs = (NSApp.delegate as? AppDelegate)?.prefs, !result.preferenceChanges.isEmpty {
                try prefs.update { p in result.preferenceChanges.forEach { $0.apply(&p) } }
                prefsApplied = result.preferenceChanges.map(\.name)
            }
            reloadTree(select: result.sites.first?.id)
            let alert = NSAlert()
            alert.messageText = "Imported \(count) site\(count == 1 ? "" : "s") from \(url.lastPathComponent)"
            let warned = result.sites.filter { !$0.importWarnings.isEmpty }
            var info = result.messages
            if !warned.isEmpty {
                info.append("\(warned.count) site(s) need attention (marked ⚠︎): " + warned.map(\.path).joined(separator: ", "))
            }
            if !prefsApplied.isEmpty { info.append("Applied WinSCP preferences: \(prefsApplied.joined(separator: ", ")).") }
            if keyCount > 0 { info.append("Imported \(keyCount) cached host key(s).") }
            info.append("Passwords were moved into the macOS Keychain. Consider deleting the .ini file; its passwords are only obfuscated, not encrypted.")
            alert.informativeText = info.joined(separator: "\n\n")
            alert.beginSheetModal(for: window!)
        } catch {
            showError(error, in: window)
        }
    }

    /// Asks for the WinSCP master password until it matches the file's verifier (or the user skips).
    private func askMasterPassword(_ data: Data) -> String? {
        var prompt = "This WinSCP.ini protects its passwords with a master password. Enter it to import the passwords, or skip to import the sites without them."
        for _ in 0..<5 {
            let a = NSAlert()
            a.messageText = "WinSCP master password"
            a.informativeText = prompt
            a.addButton(withTitle: "Import")
            a.addButton(withTitle: "Skip Passwords")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            a.accessoryView = field
            a.window.initialFirstResponder = field
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            switch WinSCPIniImporter.checkMasterPassword(field.stringValue, in: data) {
            case false?: prompt = "Incorrect master password. Try again, or skip to import the sites without passwords."
            default: return field.stringValue // verified, or no verifier: each password is MAC-checked anyway
            }
        }
        return nil
    }

    @objc private func closeWindow() { window?.close() }

    @objc private func help() {
        NSWorkspace.shared.open(URL(string: "https://github.com/corsicanu/winscp_macos#readme")!)
    }
}

extension NSColor {
    /// WinSCP stores colors as Windows COLORREF (0x00BBGGRR).
    convenience init(winscpColor c: Int) {
        self.init(srgbRed: CGFloat(c & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255,
                  blue: CGFloat((c >> 16) & 0xFF) / 255, alpha: 1)
    }
}
