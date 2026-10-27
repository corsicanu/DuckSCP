// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// WinSCP's Properties dialog: details plus an editable permission matrix.
final class PropertiesSheet: NSWindowController, NSTextFieldDelegate {
    var onApply: ((UInt32) -> Void)?
    private var boxes: [NSButton] = []
    private let octal = DuckSCP.textField(60) // qualified: NSTextFieldDelegate has textField(_:…) members
    private let original: UInt32?
    private static let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]

    init(entry: RemoteEntry, location: String) {
        original = entry.permissions
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "\(entry.name) Properties"
        super.init(window: panel)

        let kind = entry.kind == .directory ? "Folder" : entry.kind == .symlink ? "Symbolic link" : "File"
        var rows: [[NSView]] = [
            [label("Name:"), label(entry.name)],
            [label("Type:"), label(kind)],
            [label("Location:"), label(location)],
            [label("Size:"), label(entry.isDirectoryLike ? "—" : "\(Format.size(entry.size)) bytes")],
            [label("Changed:"), label(entry.modified.map(Format.date) ?? "")],
            [label("Owner:"), label(entry.owner)],
            [label("Group:"), label(entry.group)],
        ]
        if let target = entry.linkTarget { rows.insert([label("Link target:"), label(target)], at: 2) }
        let info = NSGridView(views: rows)
        info.column(at: 0).xPlacement = .trailing

        var matrixRows: [[NSView]] = [[NSGridCell.emptyContentView, label("R"), label("W"), label("X")]]
        for (i, who) in ["Owner", "Group", "Others"].enumerated() {
            var row: [NSView] = [label(who)]
            for j in 0..<3 {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxChanged))
                b.tag = i * 3 + j
                b.state = (entry.permissions ?? 0) & Self.bits[i * 3 + j] != 0 ? .on : .off
                b.isEnabled = entry.permissions != nil
                boxes.append(b)
                row.append(b)
            }
            matrixRows.append(row)
        }
        let matrix = NSGridView(views: matrixRows)
        octal.stringValue = entry.permissions.map { String($0 & 0o7777, radix: 8) } ?? ""
        octal.delegate = self
        octal.isEnabled = entry.permissions != nil
        let octalRow = NSStackView(views: [label("Octal:"), octal])

        let ok = button("OK", self, #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = button("Cancel", self, #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), ok, cancel])

        let stack = NSStackView(views: [info, NSBox.separator(), label("Permissions:"), matrix, octalRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var mode: UInt32 {
        let special = (original ?? 0) & 0o7000
        return boxes.enumerated().reduce(special) { $1.element.state == .on ? $0 | Self.bits[$1.offset] : $0 }
    }

    @objc private func boxChanged() { octal.stringValue = String(mode, radix: 8) }

    func controlTextDidChange(_ obj: Notification) {
        guard let v = UInt32(octal.stringValue, radix: 8), v <= 0o7777 else { return }
        for (i, b) in boxes.enumerated() { b.state = v & Self.bits[i] != 0 ? .on : .off }
    }

    @objc private func okPressed() {
        var newMode = mode
        if let v = UInt32(octal.stringValue, radix: 8), v <= 0o7777 { newMode = v }
        if let original, newMode != original & 0o7777 { onApply?(newMode) }
        end()
    }

    @objc private func cancelPressed() { end() }
    private func end() { window?.sheetParent?.endSheet(window!) }
}

extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}
