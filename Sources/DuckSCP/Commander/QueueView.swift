// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// The transfer queue under the panels: one row per item with direction, source,
/// destination, an accent progress bar and speed or state.
final class QueueView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private(set) var queue: TransferQueue?

    private enum Col: String, CaseIterable { case dir, source, destination, progress, state }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for c in Col.allCases {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            switch c {
            case .dir: col.width = 28; col.resizingMask = []
            case .source, .destination: col.width = 320; col.resizingMask = .autoresizingMask
            case .progress: col.width = 170; col.resizingMask = []
            case .state: col.width = 110; col.resizingMask = []
            }
            table.addTableColumn(col)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .custom
        table.rowHeight = 26
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Transfer queue")
        let menu = NSMenu()
        menu.add("Cancel", #selector(cancelSelected), target: self)
        menu.add("Remove Finished", #selector(removeFinished), target: self)
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox.separator()
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ queue: TransferQueue?) {
        self.queue = queue
        table.reloadData()
    }

    func reload() { table.reloadData() }

    func numberOfRows(in tableView: NSTableView) -> Int { queue?.items.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let content = cellContent(tableColumn, row) else { return nil }
        // Centre every cell vertically in the row.
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if content is TransferBar { content.heightAnchor.constraint(equalToConstant: 8).isActive = true }
        return cell
    }

    private func cellContent(_ tableColumn: NSTableColumn?, _ row: Int) -> NSView? {
        guard let queue, row < queue.items.count, let id = tableColumn?.identifier, let col = Col(rawValue: id.rawValue) else { return nil }
        let item = queue.items[row]
        switch col {
        case .dir:
            let up = item.direction == .upload
            let img = NSImageView(image: NSImage(systemSymbolName: up ? "arrow.up" : "arrow.down",
                                                 accessibilityDescription: up ? "Upload" : "Download") ?? NSImage())
            img.contentTintColor = item.state == .running || item.state == .connecting ? Theme.accent : .secondaryLabelColor
            img.toolTip = (up ? "Upload" : "Download") + (item.move ? " (move)" : "")
            return img
        case .source: return text(Self.tilde(item.sourceDescription, local: item.direction == .upload), secondary: false)
        case .destination: return text(item.displayTarget ?? Self.tilde(item.targetDir, local: item.direction == .download), secondary: true)
        case .progress:
            let bar = TransferBar()
            bar.fraction = item.state == .done ? 1 : item.progress.total == 0 ? 0 : Double(item.progress.totalDone) / Double(item.progress.total)
            if case .failed = item.state { bar.color = .systemRed }
            return bar
        case .state:
            let t: String
            var color = NSColor.secondaryLabelColor
            switch item.state {
            case .pending: t = "Waiting"
            case .connecting: t = "Connecting"
            case .running: t = item.speed > 0 ? "\(Format.shortSize(UInt64(item.speed)))/s" : "Starting"; color = .labelColor
            case .done: t = "Done"
            case .cancelled: t = "Cancelled"
            case .failed(let msg): t = "Failed"; color = .systemRed; _ = msg
            }
            let f = text(t, secondary: false)
            f.textColor = color
            if case .failed(let msg) = item.state { f.toolTip = msg }
            return f
        }
    }

    /// Local paths under the home folder are shown with "~", like Finder and Terminal.
    static func tilde(_ path: String, local: Bool) -> String {
        local ? (path as NSString).abbreviatingWithTildeInPath : path
    }

    private func text(_ s: String, secondary: Bool) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingMiddle
        f.toolTip = s
        f.font = .systemFont(ofSize: 12)
        f.textColor = secondary ? .secondaryLabelColor : .labelColor
        return f
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
