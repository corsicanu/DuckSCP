import AppKit
import SCPCore

/// Condensed version of WinSCP's "Advanced Site Settings" dialog.
final class AdvancedSiteSheet: NSWindowController {
    var onDone: ((Site) -> Void)?
    private var site: Site

    private let keyField = textField(280)
    private let remoteDirField = textField(280)
    private let localDirField = textField(280)
    private let noteField = textField(280)
    private let scpFallback = NSButton(checkboxWithTitle: "Allow SCP fallback", target: nil, action: nil)
    private let passive = NSButton(checkboxWithTitle: "Passive mode", target: nil, action: nil)

    init(site: Site) {
        self.site = site
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Advanced Site Settings"
        super.init(window: panel)

        keyField.stringValue = site.privateKeyPath
        remoteDirField.stringValue = site.remoteDirectory
        localDirField.stringValue = site.localDirectory
        noteField.stringValue = site.note
        scpFallback.state = site.allowScpFallback ? .on : .off
        passive.state = site.ftpPassive ? .on : .off
        scpFallback.isEnabled = site.fileProtocol == .sftp
        passive.isEnabled = site.fileProtocol == .ftp

        let grid = NSGridView(views: [
            [label("Private key file:"), keyField, button("…", self, #selector(browseKey))],
            [label("Remote directory:"), remoteDirField, NSGridCell.emptyContentView],
            [label("Local directory:"), localDirField, button("…", self, #selector(browseLocal))],
            [label("Note:"), noteField, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, scpFallback, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, passive, NSGridCell.emptyContentView],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8

        let ok = button("OK", self, #selector(done))
        ok.keyEquivalent = "\r"
        let cancel = button("Cancel", self, #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [ok, cancel])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func browseKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyField.stringValue = url.path }
    }

    @objc private func browseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { localDirField.stringValue = url.path }
    }

    @objc private func done() {
        site.privateKeyPath = keyField.stringValue
        site.remoteDirectory = remoteDirField.stringValue
        site.localDirectory = localDirField.stringValue
        site.note = noteField.stringValue
        site.allowScpFallback = scpFallback.state == .on
        site.ftpPassive = passive.state == .on
        onDone?(site)
        end()
    }

    @objc private func cancel() { end() }

    private func end() {
        window?.sheetParent?.endSheet(window!)
    }
}
