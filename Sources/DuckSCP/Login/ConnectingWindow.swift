// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// WinSCP's connection progress dialog. Also answers the connector's questions
/// (host key, password, passphrase) by blocking the connecting thread on the main queue.
final class ConnectingWindow: NSWindowController, ConnectionPrompter {
    private let log = NSTextView()
    private var cancelled = false
    private let site: Site
    private var savedPassword: String?
    /// Answers given during this connection, replayed for background connections.
    let cached = CachedPrompter()

    init(site: Site) {
        self.site = site
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "\(site.displayTarget) - \(Branding.appName)"
        super.init(window: panel)
        let scroll = NSScrollView()
        scroll.documentView = log
        log.isEditable = false
        log.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        log.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let cancel = button("Abort", self, #selector(abort))
        cancel.keyEquivalent = "\u{1b}"
        panel.contentView!.addSubview(scroll)
        panel.contentView!.addSubview(cancel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            cancel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            cancel.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            cancel.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -12),
        ])
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A password typed at the prompt, offered to the caller for saving.
    var enteredPassword: String? { savedPassword }

    @objc private func abort() {
        cancelled = true
        log.string += "Aborting...\n"
    }

    var isCancelled: Bool { onMain { self.cancelled } }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    // MARK: ConnectionPrompter

    func status(_ text: String) {
        DispatchQueue.main.async { self.log.string += text + "\n" }
    }

    func banner(_ text: String) {
        onMain {
            let a = NSAlert()
            a.messageText = "Authentication Banner - \(site.hostName)"
            a.informativeText = text
            a.runModal()
        }
    }

    func verifyHostKey(host: String, port: Int, key: HostKey, verdict: HostKeyVerdict) -> HostKeyDecision {
        let decision = askHostKey(host: host, port: port, key: key, verdict: verdict)
        if decision != .reject { cached.acceptedHostKey = key }
        return decision
    }

    private func askHostKey(host: String, port: Int, key: HostKey, verdict: HostKeyVerdict) -> HostKeyDecision {
        onMain {
            let a = NSAlert()
            let details = "\(key.type) \(key.sha256Fingerprint)"
            switch verdict {
            case .changed(let previous):
                a.alertStyle = .critical
                a.messageText = "WARNING - POTENTIAL SECURITY BREACH!"
                a.informativeText = """
                The server's host key does not match the one cached for \(host):\(port). Either the server \
                administrator changed the key, or you are connecting to a different computer pretending to be the server.

                New key: \(details)
                Cached:  \(previous)

                Connect only if you know the key was changed.
                """
                a.addButton(withTitle: "Cancel")   // first = default: safe choice
                a.addButton(withTitle: "Accept and Update")
                a.addButton(withTitle: "Connect Once")
                switch a.runModal() {
                case .alertSecondButtonReturn: return .acceptAndSave
                case .alertThirdButtonReturn: return .acceptOnce
                default: return .reject
                }
            default:
                a.messageText = "Continue connecting to an unknown server and add its host key to a cache?"
                a.informativeText = """
                The server's host key was not found in the cache. There is no guarantee the server is the computer \
                you think it is.

                \(host):\(port)
                \(details)
                MD5: \(key.md5Fingerprint)
                """
                a.addButton(withTitle: "Accept")
                a.addButton(withTitle: "Cancel")
                a.addButton(withTitle: "Connect Once")
                switch a.runModal() {
                case .alertFirstButtonReturn: return .acceptAndSave
                case .alertThirdButtonReturn: return .acceptOnce
                default: return .reject
                }
            }
        }
    }

    func verifyCertificate(host: String, port: Int, fingerprint: String, problem: String, changed: Bool) -> HostKeyDecision {
        let decision: HostKeyDecision = onMain {
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = changed ? "WARNING - POTENTIAL SECURITY BREACH!" : "The server's certificate is not trusted."
            let reason = changed ? "The certificate of \(host):\(port) differs from the one you accepted before." : problem
            a.informativeText = reason + "\n\nSHA-256 fingerprint:\n" + fingerprint
                + "\n\nCompare it with the one your server administrator gave you. Accepting pins this certificate's key, so a different certificate is reported next time."
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Accept and Remember")
            a.addButton(withTitle: "Connect Once")
            switch a.runModal() {
            case .alertSecondButtonReturn: return .acceptAndSave
            case .alertThirdButtonReturn: return .acceptOnce
            default: return .reject
            }
        }
        if decision != .reject { cached.acceptedCertificate = fingerprint }
        return decision
    }

    func askPassword(_ prompt: String) -> String? {
        let value = secret(title: "Password - \(site.displayTarget)", prompt: prompt)
        if let value {
            savedPassword = value
            cached.password = value
        }
        return value
    }

    func askPassphrase(keyPath: String) -> String? {
        let value = secret(title: "Key passphrase", prompt: "Passphrase for key \"\((keyPath as NSString).lastPathComponent)\":")
        if let value { cached.passphrases[keyPath] = value }
        return value
    }

    private func secret(title: String, prompt: String) -> String? {
        onMain {
            guard !cancelled else { return nil }
            let a = NSAlert()
            a.messageText = title
            a.informativeText = prompt
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            a.accessoryView = field
            a.window.initialFirstResponder = field
            return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }
}
