// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// WinSCP's queue list under the panels.
final class QueueView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private(set) var queue: TransferQueue?

    private enum Col: String, CaseIterable {
        case operation = "Operation", source = "Source", destination = "Destination",
             transferred = "Transferred", time = "Time", speed = "Speed", progress = "Progress"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for c in Col.allCases {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = c.rawValue
            col.width = c == .source || c == .destination ? 240 : 90
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.usesAlternatingRowBackgroundColors = true
        let menu = NSMenu()
        menu.add("Cancel", #selector(cancelSelected), target: self)
        menu.add("Remove Finished", #selector(removeFinished), target: self)
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ queue: TransferQueue?) {
        self.queue = queue
        table.reloadData()
    }

    func reload() { table.reloadData() }

    func numberOfRows(in tableView: NSTableView) -> Int { queue?.items.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let queue, row < queue.items.count, let id = tableColumn?.identifier, let col = Col(rawValue: id.rawValue) else { return nil }
        let item = queue.items[row]
        let text: String
        switch col {
        case .operation:
            text = (item.direction == .upload ? "Upload" : "Download") + (item.move ? " (move)" : "")
        case .source: text = item.sourceDescription
        case .destination: text = item.targetDir
        case .transferred: text = Format.shortSize(item.progress.totalDone)
        case .time:
            text = item.startedAt.map { Format.duration((item.finishedAt ?? Date()).timeIntervalSince($0)) } ?? ""
        case .speed: text = item.speed > 0 ? "\(Format.shortSize(UInt64(item.speed)))/s" : ""
        case .progress:
            switch item.state {
            case .pending: text = "Waiting"
            case .connecting: text = "Connecting"
            case .running:
                let pct = item.progress.total == 0 ? 0 : Int(Double(item.progress.totalDone) / Double(item.progress.total) * 100)
                text = "\(pct)%"
            case .done: text = "Done"
            case .cancelled: text = "Cancelled"
            case .failed(let msg): text = "Error: \(msg)"
            }
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        if case .failed = item.state, col == .progress { field.textColor = .systemRed }
        return field
    }

    @objc private func cancelSelected() {
        guard let queue, table.clickedRow >= 0, table.clickedRow < queue.items.count else { return }
        queue.cancel(queue.items[table.clickedRow])
    }

    @objc private func removeFinished() {
        queue?.removeFinished()
        table.reloadData()
    }
}
