import AppKit
import CoreServices
import SCPCore

/// WinSCP's Synchronize dialog → comparison → checklist preview → run.
final class SynchronizeController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let commander: CommanderWindowController
    private let tab: SessionTab
    private var actions: [Synchronizer.Action] = []
    private var checked: [Bool] = []
    private var previewPanel: NSPanel?
    private var completion: (() -> Void)?

    init(commander: CommanderWindowController, tab: SessionTab) {
        self.commander = commander
        self.tab = tab
    }

    // MARK: Step 1: options

    func start(completion: @escaping () -> Void) {
        self.completion = completion
        guard let window = commander.window else { return }
        let localField = DuckSCP.textField(380), remoteField = DuckSCP.textField(380)
        localField.stringValue = tab.local.path
        remoteField.stringValue = tab.remote.path
        let direction = NSSegmentedControl(labels: ["Both", "Remote", "Local"], trackingMode: .selectOne, target: nil, action: nil)
        direction.selectedSegment = 0
        direction.toolTip = "Both: newer side wins. Remote: make remote match local. Local: make local match remote."
        let delete = NSButton(checkboxWithTitle: "Delete files (mirror, Remote/Local only)", target: nil, action: nil)
        let criteria = NSPopUpButton()
        criteria.addItems(withTitles: ["Modification time", "File size", "Time and size"])
        let preview = NSButton(checkboxWithTitle: "Preview changes", target: nil, action: nil)
        preview.state = .on

        let grid = NSGridView(views: [
            [label("Local directory:"), localField],
            [label("Remote directory:"), remoteField],
            [label("Direction:"), direction],
            [label("Compare by:"), criteria],
            [NSGridCell.emptyContentView, delete],
            [NSGridCell.emptyContentView, preview],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 500, height: 190)

        let alert = NSAlert()
        alert.messageText = "Synchronize"
        alert.informativeText = "Excluded: \(currentPrefs.excludeMask.isEmpty ? "nothing" : currentPrefs.excludeMask) (Preferences → Transfer)"
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] r in
            guard r == .alertFirstButtonReturn else { return }
            var o = Synchronizer.Options()
            o.direction = [.both, .remote, .local][max(0, direction.selectedSegment)]
            o.criteria = [.time, .size, .timeAndSize][max(0, criteria.indexOfSelectedItem)]
            o.deleteObsolete = delete.state == .on && o.direction != .both
            o.exclude = FileMask(currentPrefs.excludeMask)
            if tab.session.protocolName.hasPrefix("FTP") { o.timeTolerance = 60 } // FTP lists minutes only
            compare(options: o, local: URL(fileURLWithPath: localField.stringValue), remote: remoteField.stringValue,
                    preview: preview.state == .on)
        }
    }

    // MARK: Step 2: compare

    private func compare(options: Synchronizer.Options, local: URL, remote: String, preview: Bool) {
        guard let window = commander.window else { return }
        let busy = ProgressSheet(title: "Comparing")
        window.beginSheet(busy.window!)
        tab.session.perform({ fs in try Synchronizer(fs: fs, options: options).plan(localRoot: local, remoteRoot: remote) }) { [self] result in
            window.endSheet(busy.window!)
            switch result {
            case .failure(let e): showError(e, in: window)
            case .success(let plan):
                actions = plan
                checked = plan.map { $0.kind != .conflict }
                if plan.isEmpty {
                    let a = NSAlert()
                    a.messageText = "Nothing to synchronize."
                    a.informativeText = "\(local.path) and \(remote) are in sync."
                    a.beginSheetModal(for: window)
                } else if preview {
                    showPreview(options: options, local: local, remote: remote)
                } else {
                    run(options: options, local: local, remote: remote)
                }
            }
        }
    }

    // MARK: Step 3: checklist

    private func showPreview(options: Synchronizer.Options, local: URL, remote: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = "Synchronization Checklist"
        let table = NSTableView()
        for (id, title, width) in [("on", "", 24.0), ("action", "Action", 110.0), ("path", "Name", 380.0), ("size", "Size", 90.0), ("reason", "Reason", 200.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let summary = label("\(actions.count) change(s), \(Format.shortSize(actions.reduce(0) { $0 + $1.size })) to transfer")
        let ok = button("Synchronize", nil, nil)
        ok.keyEquivalent = "\r"
        let cancel = button("Cancel", nil, nil)
        cancel.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [summary, NSView(), ok, cancel])
        bar.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(scroll)
        panel.contentView!.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -12),
        ])
        previewAction = { [weak self] confirmed in
            guard let self, let window = self.commander.window else { return }
            window.endSheet(panel)
            self.previewPanel = nil
            if confirmed { self.run(options: options, local: local, remote: remote) }
        }
        ok.target = self
        ok.action = #selector(previewOK)
        cancel.target = self
        cancel.action = #selector(previewCancel)
        previewPanel = panel
        commander.window?.beginSheet(panel)
    }

    private var previewAction: ((Bool) -> Void)?
    @objc private func previewOK() { previewAction?(true) }
    @objc private func previewCancel() { previewAction?(false) }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let a = actions[row]
        switch col?.identifier.rawValue {
        case "on":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            b.tag = row
            b.state = checked[row] ? .on : .off
            b.isEnabled = a.kind != .conflict
            return b
        case "action":
            let text: String
            switch a.kind {
            case .upload: text = "→ Upload"
            case .download: text = "← Download"
            case .deleteLocal: text = "✕ Delete local"
            case .deleteRemote: text = "✕ Delete remote"
            case .conflict: text = "⚠︎ Conflict"
            }
            return label(text)
        case "path": return label(a.relativePath + (a.isDirectory ? "/" : ""))
        case "size": return label(a.isDirectory ? "" : Format.size(a.size))
        default:
            let l = label(a.reason)
            l.textColor = .secondaryLabelColor
            return l
        }
    }

    @objc private func toggle(_ sender: NSButton) { checked[sender.tag] = sender.state == .on }

    // MARK: Step 4: run

    private func run(options: Synchronizer.Options, local: URL, remote: String) {
        let selected = zip(actions, checked).filter { $0.1 }.map(\.0)
        let transfer = currentPrefs.transferOptions
        let useTrash = currentPrefs.useTrashForLocalDelete
        commander.transfers.runForeground(title: "Synchronizing", session: tab.session, work: { fs, _, report in
            try Synchronizer(fs: fs, options: options).run(selected, localRoot: local, remoteRoot: remote, transfer: transfer,
                                                           trash: useTrash ? { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) } : nil,
                                                           report: report)
        }, completion: { [self] in
            tab.local.refresh()
            tab.remote.refresh()
            completion?()
        })
    }
}

/// WinSCP's "Keep Remote Directory up to Date": watches a local folder with FSEvents
/// and uploads changes (optionally deleting remote files that were removed locally).
final class KeepUpToDateWindow: NSWindowController, NSWindowDelegate {
    private let tab: SessionTab
    private let localField = DuckSCP.textField(420)
    private let remoteField = DuckSCP.textField(420)
    private let deleteBox = NSButton(checkboxWithTitle: "Delete remote files removed locally", target: nil, action: nil)
    private let initialBox = NSButton(checkboxWithTitle: "Synchronize on start", target: nil, action: nil)
    private let startButton = button("Start", nil, nil)
    private let log = NSTextView()
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var busy = false
    private var dirty = false

    init(tab: SessionTab) {
        self.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Keep Remote Directory up to Date - \(tab.session.site.displayTarget)"
        super.init(window: window)
        window.delegate = self
        localField.stringValue = tab.local.path
        remoteField.stringValue = tab.remote.path
        initialBox.state = .on
        startButton.target = self
        startButton.action = #selector(toggle)
        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = log
        log.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let grid = NSGridView(views: [
            [label("Watch local directory:"), localField],
            [label("Remote directory:"), remoteField],
            [NSGridCell.emptyContentView, deleteBox],
            [NSGridCell.emptyContentView, initialBox],
            [NSGridCell.emptyContentView, startButton],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(grid)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func append(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.string += "\(f.string(from: Date())) \(text)\n"
        log.scrollToEndOfDocument(nil)
    }

    func debugStart(remote: String) {
        remoteField.stringValue = remote
        start()
    }

    @objc private func toggle() {
        if stream != nil { stop() } else { start() }
    }

    private func start() {
        let dir = localField.stringValue
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return append("Local directory does not exist.")
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let me = Unmanaged<KeepUpToDateWindow>.fromOpaque(info!).takeUnretainedValue()
            me.scheduleSync()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [dir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else {
            return append("Cannot watch \(dir).")
        }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        startButton.title = "Stop"
        [localField, remoteField, deleteBox, initialBox].forEach { $0.isEnabled = false }
        append("Watching \(dir) → \(remoteField.stringValue)")
        if initialBox.state == .on { syncNow() }
    }

    private func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        pending?.cancel()
        startButton.title = "Start"
        [localField, remoteField, deleteBox, initialBox].forEach { $0.isEnabled = true }
        append("Stopped.")
    }

    /// Debounces bursts of file events (editors save in several steps).
    fileprivate func scheduleSync() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func syncNow() {
        guard !busy else { dirty = true; return }
        busy = true
        var o = Synchronizer.Options()
        o.direction = .remote
        o.deleteObsolete = deleteBox.state == .on
        o.exclude = FileMask(currentPrefs.excludeMask)
        let local = URL(fileURLWithPath: localField.stringValue), remote = remoteField.stringValue
        let transfer = currentPrefs.transferOptions
        tab.session.perform({ fs -> [Synchronizer.Action] in
            let s = Synchronizer(fs: fs, options: o)
            let plan = try s.plan(localRoot: local, remoteRoot: remote).filter { $0.kind != .conflict }
            try s.run(plan, localRoot: local, remoteRoot: remote, transfer: transfer, report: { _ in true })
            return plan
        }) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let plan):
                for a in plan { self.append("\(a.kind == .deleteRemote ? "Deleted" : "Uploaded") \(a.relativePath)") }
                if !plan.isEmpty { self.tab.remote.refresh() }
            case .failure(let e):
                self.append("Error: \(e)")
            }
            if self.dirty { self.dirty = false; self.scheduleSync() }
        }
    }

    func windowWillClose(_ notification: Notification) { if stream != nil { stop() } }
}
