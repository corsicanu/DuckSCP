// SPDX-License-Identifier: GPL-3.0-or-later
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
    private let compression = NSButton(checkboxWithTitle: "Enable SSH compression", target: nil, action: nil)
    private let timeOffset = textField(80)
    private let s3Region = textField(160)
    private let proxyKind = NSPopUpButton()
    private let proxyHost = textField(200)
    private let proxyPort = textField(70)
    private let proxyUser = textField(200)
    private let proxyPassword = NSSecureTextField()
    private let secrets: SecretStore?

    init(site: Site, secrets: SecretStore? = nil) {
        self.site = site
        self.secrets = secrets
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
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
        compression.state = site.sshCompression ? .on : .off
        compression.isEnabled = site.fileProtocol == .sftp || site.fileProtocol == .scp
        timeOffset.stringValue = site.timeOffsetHours == 0 ? "0" : String(site.timeOffsetHours)
        timeOffset.toolTip = "Hours added to remote file times, for servers that list times in another time zone."
        s3Region.stringValue = site.s3Region
        s3Region.isEnabled = site.fileProtocol == .s3
        ProxySettings.Kind.allCases.forEach { proxyKind.addItem(withTitle: $0.title) }
        proxyKind.selectItem(at: ProxySettings.Kind.allCases.firstIndex(of: site.proxy.kind) ?? 0)
        proxyHost.stringValue = site.proxy.host
        proxyPort.stringValue = String(site.proxy.port)
        proxyUser.stringValue = site.proxy.user
        proxyPassword.placeholderString = secrets?.password(for: site.proxy.secretID) != nil ? "(saved in Keychain)" : nil
        proxyPassword.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let proxyRow = NSStackView(views: [proxyKind, proxyHost, label(":"), proxyPort])
        let proxyAuth = NSStackView(views: [proxyUser, proxyPassword])

        let grid = NSGridView(views: [
            [label("Private key file:"), keyField, button("…", self, #selector(browseKey))],
            [label("Remote directory:"), remoteDirField, NSGridCell.emptyContentView],
            [label("Local directory:"), localDirField, button("…", self, #selector(browseLocal))],
            [label("Note:"), noteField, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, scpFallback, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, passive, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, compression, NSGridCell.emptyContentView],
            [label("Timezone offset (h):"), timeOffset, NSGridCell.emptyContentView],
            [label("S3 region:"), s3Region, NSGridCell.emptyContentView],
            [label("Proxy:"), proxyRow, NSGridCell.emptyContentView],
            [label("Proxy user / password:"), proxyAuth, NSGridCell.emptyContentView],
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
        site.sshCompression = compression.state == .on
        site.timeOffsetHours = Double(timeOffset.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
        site.s3Region = s3Region.stringValue.trimmingCharacters(in: .whitespaces)
        site.proxy.kind = ProxySettings.Kind.allCases[max(0, proxyKind.indexOfSelectedItem)]
        site.proxy.host = proxyHost.stringValue.trimmingCharacters(in: .whitespaces)
        site.proxy.port = Int(proxyPort.stringValue) ?? 1080
        site.proxy.user = proxyUser.stringValue
        if !proxyPassword.stringValue.isEmpty {
            // Stored at once under the proxy's own Keychain entry, separate from the site password.
            try? secrets?.setPassword(proxyPassword.stringValue, for: site.proxy.secretID)
        }
        onDone?(site)
        end()
    }

    @objc private func cancel() { end() }

    private func end() {
        window?.sheetParent?.endSheet(window!)
    }
}
