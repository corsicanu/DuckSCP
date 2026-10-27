import AppKit
import SCPCore
import UniformTypeIdentifiers

/// Where a panel reads directory listings from.
protocol PanelBackend: AnyObject {
    var isLocal: Bool { get }
    var homeDirectory: String { get }
    func list(_ path: String, completion: @escaping (Result<[RemoteEntry], Error>) -> Void)
}

final class LocalBackend: PanelBackend {
    private let fs = LocalFileSystem()
    private let queue = DispatchQueue(label: "local.listing", qos: .userInitiated)
    var isLocal: Bool { true }
    var homeDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func list(_ path: String, completion: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        queue.async { [fs] in
            let r = Result { try fs.list(path) }
            DispatchQueue.main.async { completion(r) }
        }
    }
}

final class RemoteBackend: PanelBackend {
    let session: RemoteSession
    init(session: RemoteSession) { self.session = session }
    var isLocal: Bool { false }
    var homeDirectory: String { session.homeDirectory }

    func list(_ path: String, completion: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        session.perform({ try $0.list(path) }, completion: completion)
    }
}

protocol FilePanelDelegate: AnyObject {
    func panelDidBecomeActive(_ panel: FilePanel)
    func panel(_ panel: FilePanel, command: PanelCommand)
    func panelPathDidChange(_ panel: FilePanel)
    func panel(_ panel: FilePanel, didFail error: Error)
}

enum PanelCommand { case copy, move, delete, rename, makeDirectory, properties, edit, open, switchPanel }

/// Column ids, WinSCP's defaults per side.
enum PanelColumn: String {
    case name = "Name", size = "Size", type = "Type", changed = "Changed", rights = "Rights", owner = "Owner", attr = "Attr"
}

/// One side of the Commander window: path bar, file list, status line.
final class FilePanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let backend: PanelBackend
    weak var delegate: FilePanelDelegate?

    private(set) var path: String
    /// Path before the last successful navigation (for synchronized browsing).
    private(set) var previousPath: String?
    /// Set when synchronized browsing moves this panel, so the move is not mirrored back.
    var navigatedBySync = false
    private(set) var entries: [RemoteEntry] = []
    /// Unfiltered listing; `entries` hides dot files unless "Show hidden files" is on.
    private var allEntries: [RemoteEntry] = []

    static func visible(_ list: [RemoteEntry]) -> [RemoteEntry] {
        currentPrefs.showHiddenFiles ? list : list.filter { !$0.name.hasPrefix(".") }
    }

    /// Re-applies display preferences (hidden files, size format) without re-listing.
    func preferencesChanged() {
        pendingSelection = selectedEntries.first?.name
        entries = Self.visible(allEntries)
        sortAndReload()
    }
    private var history: [String] = []
    private var future: [String] = []
    private var pendingSelection: String?
    private var hasLoaded = false

    private let table = PanelTableView()
    private let pathPopup = NSPopUpButton()
    private let statusLabel = label("")
    private var headerBar = HighlightStackView()
    private let columns: [PanelColumn]

    static let parentName = ".."

    init(backend: PanelBackend, path: String?) {
        self.backend = backend
        self.path = path?.isEmpty == false ? path! : backend.homeDirectory
        columns = backend.isLocal ? [.name, .size, .type, .changed, .attr] : [.name, .size, .changed, .rights, .owner]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override func loadView() {
        let root = NSView()

        pathPopup.target = self
        pathPopup.action = #selector(pathPicked)
        pathPopup.translatesAutoresizingMaskIntoConstraints = false
        pathPopup.controlSize = .small

        let nav = NSStackView(views: [
            toolButton("chevron.left", "Back", #selector(goBack)),
            toolButton("chevron.right", "Forward", #selector(goForward)),
            toolButton("arrow.turn.left.up", "Parent directory", #selector(goParent)),
            toolButton("externaldrive", "Root directory", #selector(goRoot)),
            toolButton("house", "Home directory", #selector(goHome)),
            toolButton("arrow.clockwise", "Refresh", #selector(refresh)),
        ])
        nav.spacing = 2
        headerBar = HighlightStackView(views: [pathPopup, nav])
        headerBar.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        headerBar.wantsLayer = true
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.setHuggingPriority(.required, for: .vertical)
        pathPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        for c in columns {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = c.rawValue
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: true)
            switch c {
            case .name: col.width = 200
            case .size: col.width = 80; col.headerCell.alignment = .right
            case .changed: col.width = 130
            case .type: col.width = 110
            default: col.width = 80
            }
            table.addTableColumn(col)
        }
        table.sortDescriptors = [NSSortDescriptor(key: PanelColumn.name.rawValue, ascending: true)]
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.rowSizeStyle = .small
        table.style = .plain
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.panel = self
        table.menu = contextMenu()
        table.registerForDraggedTypes([.fileURL, .panelEntries])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false) // local: file URLs; remote: file promises

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        [headerBar, scroll, statusLabel].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: root.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -6),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
        ])
        view = root
        setActive(false)
        load(path, recordHistory: false)
    }

    private func toolButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tip
        b.controlSize = .small
        return b
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.add("Open", #selector(openSelected), target: self)
        m.add("Edit", #selector(cmdEdit), target: self)
        m.addItem(.separator())
        m.add(backend.isLocal ? "Upload…" : "Download…", #selector(cmdCopy), target: self)
        m.add("Move…", #selector(cmdMove), target: self)
        m.addItem(.separator())
        m.add("Delete", #selector(cmdDelete), target: self)
        m.add("Rename", #selector(cmdRename), target: self)
        m.addItem(.separator())
        m.add("New Directory…", #selector(cmdMakeDir), target: self)
        m.add("Copy Path to Clipboard", #selector(copyPath), target: self)
        m.add("Properties", #selector(cmdProperties), target: self)
        return m
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cmdMakeDir), #selector(copyPath): return true
        case #selector(cmdRename), #selector(cmdEdit): return selectedEntries.count == 1
        default: return !selectedEntries.isEmpty
        }
    }

    // MARK: Active state

    private(set) var isActive = false

    func setActive(_ active: Bool) {
        isActive = active
        headerBar.highlighted = active
    }

    func focus() {
        view.window?.makeFirstResponder(table)
    }

    fileprivate func tableBecameFirstResponder() {
        delegate?.panelDidBecomeActive(self)
    }

    // MARK: Navigation

    func load(_ newPath: String, recordHistory: Bool = true, select: String? = nil) {
        let previous = path
        backend.list(newPath) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let list):
                self.hasLoaded = true
                if recordHistory && newPath != previous {
                    self.history.append(previous)
                    self.future.removeAll()
                }
                self.previousPath = self.path
                self.path = newPath
                self.allEntries = list
                self.entries = Self.visible(list)
                self.pendingSelection = select
                self.sortAndReload()
                self.rebuildPathPopup()
                self.delegate?.panelPathDidChange(self)
            case .failure(let error):
                self.navigatedBySync = false
                self.delegate?.panel(self, didFail: error)
                // The configured start folder may be gone: fall back to home once.
                if !self.hasLoaded && newPath != self.backend.homeDirectory {
                    self.path = self.backend.homeDirectory
                    self.load(self.path, recordHistory: false)
                }
            }
        }
    }

    @objc func refresh() {
        let keep = selectedEntries.first?.name
        load(path, recordHistory: false, select: keep)
    }

    @objc func goParent() {
        guard path != "/" else { return }
        load(RemotePath.parent(path), select: RemotePath.name(path))
    }

    @objc func goRoot() { load("/") }
    @objc func goHome() { load(backend.homeDirectory) }

    @objc func goBack() {
        guard let p = history.popLast() else { return NSSound.beep() }
        future.append(path)
        load(p, recordHistory: false)
    }

    @objc func goForward() {
        guard let p = future.popLast() else { return NSSound.beep() }
        history.append(path)
        load(p, recordHistory: false)
    }

    private func rebuildPathPopup() {
        pathPopup.removeAllItems()
        var comps: [String] = ["/"]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/" + part
            comps.append(acc)
        }
        for (depth, p) in comps.enumerated() {
            pathPopup.addItem(withTitle: p == "/" ? "/" : String(p.split(separator: "/").last!))
            pathPopup.lastItem?.representedObject = p
            pathPopup.lastItem?.indentationLevel = depth
            pathPopup.lastItem?.image = NSImage(systemSymbolName: depth == 0 ? (backend.isLocal ? "internaldrive" : "server.rack") : "folder", accessibilityDescription: nil)
        }
        pathPopup.selectItem(at: comps.count - 1)
        pathPopup.toolTip = path
    }

    @objc private func pathPicked() {
        if let p = pathPopup.selectedItem?.representedObject as? String { load(p) }
    }

    // MARK: Data

    /// Row 0 is ".." except at the root, like WinSCP.
    private var hasParentRow: Bool { path != "/" }

    private func entry(at row: Int) -> RemoteEntry? {
        if hasParentRow {
            return row == 0 ? nil : entries[row - 1]
        }
        return entries[row]
    }

    var selectedEntries: [RemoteEntry] {
        table.selectedRowIndexes.compactMap { $0 < table.numberOfRows ? entry(at: $0) : nil }
    }

    func selectedPaths() -> [String] { selectedEntries.map { RemotePath.join(path, $0.name) } }

    private func sortAndReload() {
        let sd = table.sortDescriptors.first ?? NSSortDescriptor(key: PanelColumn.name.rawValue, ascending: true)
        let key = PanelColumn(rawValue: sd.key ?? "") ?? .name
        let sortKey: EntrySort.Key
        switch key {
        case .name: sortKey = .name
        case .size: sortKey = .size
        case .changed: sortKey = .changed
        case .rights, .attr: sortKey = .rights
        case .owner: sortKey = .owner
        case .type: sortKey = .type
        }
        EntrySort.sort(&entries, by: sortKey, ascending: sd.ascending, typeName: typeName)
        table.reloadData()
        var row = 0
        if let name = pendingSelection, let i = entries.firstIndex(where: { $0.name == name }) {
            row = i + (hasParentRow ? 1 : 0)
        }
        pendingSelection = nil
        if table.numberOfRows > 0 {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateStatus()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        pendingSelection = selectedEntries.first?.name
        sortAndReload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count + (hasParentRow ? 1 : 0) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = PanelColumn(rawValue: id.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, withImage: column == .name)
        let e = entry(at: row)
        let text: String
        switch column {
        case .name:
            text = e?.name ?? FilePanel.parentName
            cell.imageView?.image = icon(for: e)
        case .size: text = e.map { $0.isDirectoryLike ? "" : Format.size($0.size) } ?? ""
        case .type: text = e.map(typeName) ?? "Parent directory"
        case .changed: text = e?.modified.map(Format.date) ?? ""
        case .rights, .attr: text = e?.rightsString ?? ""
        case .owner: text = e?.owner ?? ""
        }
        cell.textField?.stringValue = text
        cell.textField?.alignment = column == .size ? .right : .left
        cell.toolTip = e?.linkTarget.map { "→ \($0)" }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4)
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(for e: RemoteEntry?) -> NSImage? {
        guard let e else { return NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: nil) }
        if backend.isLocal {
            return NSWorkspace.shared.icon(forFile: RemotePath.join(path, e.name))
        }
        if e.isDirectoryLike { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (e.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private func typeName(_ e: RemoteEntry) -> String {
        if e.isDirectoryLike { return "File folder" }
        let ext = (e.name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "File" : ext.uppercased() + " File")
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }

    /// "0 B of 1.2 MB in 0 of 15" like WinSCP's panel status line.
    private func updateStatus() {
        let sel = selectedEntries
        let selSize = sel.filter { !$0.isDirectoryLike }.reduce(0) { $0 + $1.size }
        let total = entries.filter { !$0.isDirectoryLike }.reduce(0) { $0 + $1.size }
        statusLabel.stringValue = "\(Format.shortSize(selSize)) of \(Format.shortSize(total)) in \(sel.count) of \(entries.count)"
    }

    // MARK: Commands

    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        guard let e = entry(at: row) else { return goParent() }
        if e.isDirectoryLike {
            load(RemotePath.join(path, e.name))
        } else {
            delegate?.panel(self, command: .open)
        }
    }

    @objc func cmdCopy() { delegate?.panel(self, command: .copy) }
    @objc func cmdMove() { delegate?.panel(self, command: .move) }
    @objc func cmdDelete() { delegate?.panel(self, command: .delete) }
    @objc func cmdRename() { delegate?.panel(self, command: .rename) }
    @objc func cmdMakeDir() { delegate?.panel(self, command: .makeDirectory) }
    @objc func cmdProperties() { delegate?.panel(self, command: .properties) }
    @objc func cmdEdit() { delegate?.panel(self, command: .edit) }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        let paths = selectedPaths()
        NSPasteboard.general.setString(paths.isEmpty ? path : paths.joined(separator: "\n"), forType: .string)
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: openSelected(); return true            // Return, Enter
        case 51 where !event.modifierFlags.contains(.command): goParent(); return true // Backspace
        case 48: delegate?.panel(self, command: .switchPanel); return true // Tab
        default: return false
        }
    }

    // MARK: Drag and drop

    /// Writes a remote entry into a folder chosen by Finder (drag out of the remote panel).
    var promiseWriter: ((RemoteEntry, String, URL, @escaping (Error?) -> Void) -> Void)?

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let e = entry(at: row) else { return nil }
        if !backend.isLocal, promiseWriter != nil {
            let type = e.isDirectoryLike ? UTType.folder : (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data)
            let provider = PanelPromiseProvider(fileType: type.identifier, delegate: self)
            provider.entry = e
            provider.path = RemotePath.join(path, e.name)
            return provider
        }
        let item = NSPasteboardItem()
        item.setString(RemotePath.join(path, e.name), forType: .panelEntries)
        if backend.isLocal {
            item.setString(URL(fileURLWithPath: RemotePath.join(path, e.name)).absoluteString, forType: .fileURL)
        }
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? PanelTableView)?.panel !== self else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    var onDrop: ((FilePanel, [String], _ fromPanel: FilePanel?) -> Void)?

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let source = (info.draggingSource as? PanelTableView)?.panel
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let paths: [String]
        if source != nil {
            paths = items.compactMap { $0.string(forType: .panelEntries) }
        } else {
            paths = items.compactMap { $0.string(forType: .fileURL).flatMap { URL(string: $0)?.path } }
        }
        guard !paths.isEmpty else { return false }
        onDrop?(self, paths, source)
        return true
    }
}

/// File promise for a remote entry; also carries the panel path so in-app drops still work.
final class PanelPromiseProvider: NSFilePromiseProvider {
    var entry: RemoteEntry?
    var path = ""

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.panelEntries]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .panelEntries ? path : super.pasteboardPropertyList(forType: type)
    }
}

extension FilePanel: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? PanelPromiseProvider)?.entry?.name ?? "download"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let p = provider as? PanelPromiseProvider, let e = p.entry, let writer = promiseWriter else {
            return completionHandler(FileSystemError(.other, "Nothing to download."))
        }
        writer(e, RemotePath.parent(p.path), url.deletingLastPathComponent(), completionHandler)
    }
}

extension NSPasteboard.PasteboardType {
    static let panelEntries = NSPasteboard.PasteboardType("local.duckscp.panel-entry")
}

/// WinSCP highlights the active panel's path bar. CGColors don't follow appearance
/// changes, so the colour is re-resolved whenever light/dark switches.
final class HighlightStackView: NSStackView {
    var highlighted = false { didSet { updateColor() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        }
    }
}

final class PanelTableView: NSTableView {
    weak var panel: FilePanel?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { panel?.tableBecameFirstResponder() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if panel?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

enum Format {
    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    /// Size column text in the format chosen in Preferences → Panels.
    static func size(_ bytes: UInt64) -> String {
        switch currentPrefs.sizeFormat {
        case .bytes: return exact(bytes)
        case .kilobytes: return exact((bytes + 1023) / 1024) + " KB"
        case .short: return shortSize(bytes)
        }
    }

    /// Exact byte counts with grouping, WinSCP's default size format.
    static func exact(_ bytes: UInt64) -> String { number.string(from: NSNumber(value: bytes)) ?? "\(bytes)" }

    static func shortSize(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }

    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
