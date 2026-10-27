import AppKit
import SCPCore

/// WinSCP's Find Files dialog. Searches on its own connection so the panels stay usable.
final class FindFilesWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let tab: SessionTab
    private let rootField = MacSCP.textField(300)
    private let maskField = MacSCP.textField(160)
    private let startButton = button("Start", nil, nil)
    private let status = label("")
    private let table = NSTableView()
    private var results: [(dir: String, entry: RemoteEntry)] = []
    private var running = false
    private var stopRequested = false
    var onReveal: ((String, String) -> Void)?

    init(tab: SessionTab) {
        self.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Find Files - \(tab.session.site.displayTarget)"
        super.init(window: window)
        window.delegate = self
        rootField.stringValue = tab.remote.path
        maskField.stringValue = "*.*"
        maskField.placeholderString = "*.log; report*"
        startButton.target = self
        startButton.action = #selector(toggle)
        startButton.keyEquivalent = "\r"
        for (id, title, w) in [("name", "Name", 220.0), ("dir", "Directory", 300.0), ("size", "Size", 90.0), ("changed", "Changed", 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.target = self
        table.doubleAction = #selector(reveal)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label("Search in:"), rootField, label("File mask:"), maskField, startButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        let content = window.contentView!
        [row, scroll, status].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        if running { stopRequested = true; return }
        results.removeAll()
        table.reloadData()
        running = true
        stopRequested = false
        startButton.title = "Stop"
        status.stringValue = "Connecting..."
        var c = FileFinder.Criteria()
        c.mask = FileMask(maskField.stringValue.isEmpty ? "*" : maskField.stringValue)
        let root = rootField.stringValue, connect = tab.session.makeConnection
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: Error?
            do {
                let fs = try connect()
                defer { fs.close() }
                var lastDir = ""
                FileFinder(fs: fs, criteria: c).search(root, shouldContinue: { self?.stopRequested == false }) { dir, e in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.results.append((dir, e))
                        self.table.noteNumberOfRowsChanged()
                        if dir != lastDir { lastDir = dir; self.status.stringValue = "Searching \(dir)… \(self.results.count) found" }
                    }
                }
            } catch let e { error = e }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.startButton.title = "Start"
                self.status.stringValue = error.map { "Error: \($0)" } ?? "\(self.results.count) file(s) found\(self.stopRequested ? " (stopped)" : "")."
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = results[row]
        switch col?.identifier.rawValue {
        case "name": return label(r.entry.name)
        case "dir": return label(r.dir)
        case "size": return label(r.entry.isDirectoryLike ? "" : Format.size(r.entry.size))
        default: return label(r.entry.modified.map(Format.date) ?? "")
        }
    }

    /// Double-click: show the file in the remote panel.
    @objc private func reveal() {
        guard table.clickedRow >= 0, table.clickedRow < results.count else { return }
        let r = results[table.clickedRow]
        tab.remote.load(r.dir, select: r.entry.name)
        tab.remote.view.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { stopRequested = true }
}
