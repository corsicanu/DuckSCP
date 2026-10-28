// SPDX-License-Identifier: GPL-3.0-or-later
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
    func panelSummaryDidChange(_ panel: FilePanel)
    func panel(_ panel: FilePanel, rename entry: RemoteEntry, to name: String)
}

enum PanelCommand { case copy, move, delete, rename, makeDirectory, properties, edit, open, switchPanel }

/// Column ids, WinSCP's defaults per side.
enum PanelColumn: String {
    case name = "Name", size = "Size", type = "Type", changed = "Changed", rights = "Rights", owner = "Owner", attr = "Attr"
}

/// One side of the Commander window: path bar, file list, status line.
final class FilePanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSTextFieldDelegate {
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
    private let breadcrumb = BreadcrumbBar()
    private let edge = AccentEdge()
    /// "2 of 7 selected · 226 KB", shown in the window's status bar for the active panel.
    private(set) var summary = ""
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

        let nav = NSStackView(views: [
            toolButton("chevron.left", "Back", #selector(goBack)),
            toolButton("chevron.right", "Forward", #selector(goForward)),
            toolButton("arrow.up", "Parent folder", #selector(goParent)),
        ])
        nav.spacing = 0
        breadcrumb.onNavigate = { [weak self] p in self?.load(p) }
        breadcrumb.onEdit = { [weak self] in self?.goToFolder() }
        breadcrumb.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = NSStackView(views: [
            toolButton("house", "Home folder", #selector(goHome)),
            toolButton("arrow.clockwise", "Refresh", #selector(refresh)),
        ])
        trailing.spacing = 0
        let header = NSStackView(views: [nav, breadcrumb, trailing])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setHuggingPriority(.required, for: .vertical)
        let headerLine = NSBox.separator()
        headerLine.translatesAutoresizingMaskIntoConstraints = false

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
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .custom
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
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
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        edge.translatesAutoresizingMaskIntoConstraints = false
        [header, headerLine, scroll, edge].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 3),
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
        b.contentTintColor = .secondaryLabelColor
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.setAccessibilityLabel(tip)
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
        edge.isHidden = !active // the active panel gets the accent edge
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
        breadcrumb.show(path: path, home: backend.isLocal ? backend.homeDirectory : nil)
    }

    /// Double-click the path (or ⌘L): type a folder to open.
    @objc func goToFolder() {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Go to folder"
        a.addButton(withTitle: "Go")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = path
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            var p = field.stringValue.trimmingCharacters(in: .whitespaces)
            if self.backend.isLocal { p = (p as NSString).expandingTildeInPath }
            if !p.isEmpty { self.load(p) }
        }
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

    /// Re-applies the selection look after activation changes AppKit didn't see
    /// (the snapshot run forces the active appearance without real focus).
    func refreshSelectionLook() {
        table.enumerateAvailableRowViews { row, _ in
            row.isEmphasized = isActive
            row.needsDisplay = true
        }
    }

    // MARK: Inline rename

    private var renaming: (field: NSTextField, entry: RemoteEntry)?

    /// Turns the name cell into an editor with the base name selected (Finder style).
    /// Return renames, Escape or clicking away without changes cancels.
    func beginInlineRename(row: Int) {
        guard renaming == nil, row >= 0, row < table.numberOfRows, let e = entry(at: row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        table.scrollRowToVisible(row)
        renaming = (field, e)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.delegate = self
        field.stringValue = e.name
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let ext = (e.name as NSString).pathExtension
            let base = e.isDirectoryLike || ext.isEmpty || e.name.hasPrefix(".") && !e.name.dropFirst().contains(".")
                ? e.name.count : e.name.count - ext.count - 1
            editor.selectedRange = NSRange(location: 0, length: (e.name as NSString).substring(to: base).utf16.count)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let r = renaming, control === r.field else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            r.field.stringValue = r.entry.name
            finishInlineRename(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let r = renaming, obj.object as? NSTextField === r.field else { return }
        finishInlineRename(commit: true)
    }

    private func finishInlineRename(commit: Bool) {
        guard let r = renaming else { return }
        renaming = nil
        let newName = r.field.stringValue.trimmingCharacters(in: .whitespaces)
        r.field.isEditable = false
        r.field.isBordered = false
        r.field.drawsBackground = false
        r.field.delegate = nil
        view.window?.makeFirstResponder(table)
        if commit, !newName.isEmpty, newName != r.entry.name {
            delegate?.panel(self, rename: r.entry, to: newName)
        } else {
            r.field.stringValue = r.entry.name
            table.reloadData()
        }
    }

    /// Selects entries by name (used by the demo scene and after renames).
    func selectNames(_ names: Set<String>) {
        var rows = IndexSet()
        for (i, e) in entries.enumerated() where names.contains(e.name) { rows.insert(i + (hasParentRow ? 1 : 0)) }
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// The single selected row, if exactly one non-".." row is selected.
    var selectedRow: Int? {
        let rows = table.selectedRowIndexes
        guard rows.count == 1, let r = rows.first, entry(at: r) != nil else { return nil }
        return r
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
        case .changed: text = e?.modified.map(Format.shortDate) ?? ""
        case .rights, .attr: text = e?.rightsString ?? ""
        case .owner: text = e?.owner ?? ""
        }
        cell.textField?.stringValue = text
        cell.textField?.alignment = column == .size ? .right : .left
        cell.toolTip = column == .changed ? e?.modified.map(Format.date) : e?.linkTarget.map { "→ \($0)" }
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
        let full = RemotePath.join(path, e.name)
        if backend.isLocal, FileManager.default.fileExists(atPath: full) {
            return NSWorkspace.shared.icon(forFile: full)
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

    /// "2 of 7 selected · 226 KB" (or "7 items · 1.2 MB" with nothing selected).
    private func updateStatus() {
        let sel = selectedEntries
        if sel.isEmpty {
            let total = entries.filter { !$0.isDirectoryLike }.reduce(0) { $0 + $1.size }
            summary = "\(entries.count) item\(entries.count == 1 ? "" : "s") · \(Format.shortSize(total))"
        } else {
            let size = sel.filter { !$0.isDirectoryLike }.reduce(0) { $0 + $1.size }
            summary = "\(sel.count) of \(entries.count) selected · \(Format.shortSize(size))"
        }
        delegate?.panelSummaryDidChange(self)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AccentRowView() }

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
        // Dropping onto a folder row targets that folder; anywhere else, the open folder.
        if op == .on, let e = row < tableView.numberOfRows ? entry(at: row) : nil, e.isDirectoryLike {
            return .copy
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    /// (panel, dropped paths, source panel or nil for Finder, suggested target folder)
    var onDrop: ((FilePanel, [String], _ fromPanel: FilePanel?, _ target: String) -> Void)?

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
        var target = path
        if row >= 0, row < tableView.numberOfRows, let e = entry(at: row), e.isDirectoryLike { target = RemotePath.join(path, e.name) }
        onDrop?(self, paths, source, target)
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

final class PanelTableView: NSTableView {
    weak var panel: FilePanel?
    /// Finder's "slow double click": click a selected name again, wait, and it becomes editable.
    private var pendingRename: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        pendingRename?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point), col = column(at: point)
        let wasOnlySelection = row >= 0 && selectedRowIndexes == IndexSet(integer: row)
        let wasFocused = window?.firstResponder === self
        let start = NSEvent.mouseLocation
        super.mouseDown(with: event) // returns on mouse up (or after a drag)
        let moved = hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) > 3
        guard event.clickCount == 1, wasOnlySelection, wasFocused, !moved, col == 0,
              selectedRowIndexes == IndexSet(integer: row) else { return }
        let work = DispatchWorkItem { [weak self] in self?.panel?.beginInlineRename(row: row) }
        pendingRename = work
        // Wait out the double-click interval, so a double click still opens the item.
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.05, execute: work)
    }

    func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { panel?.tableBecameFirstResponder() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        cancelPendingRename()
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
