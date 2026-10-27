// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// Runs copy/move operations between the panels of the current tab:
/// the WinSCP "Copy" confirmation, the progress dialog and overwrite prompts.
final class TransferController {
    unowned let commander: CommanderWindowController
    private(set) var bytesTransferred: UInt64 = 0
    var options = TransferEngine.Options()

    init(commander: CommanderWindowController) { self.commander = commander }

    var statusText: String { bytesTransferred == 0 ? "" : "Transferred: \(Format.shortSize(bytesTransferred))" }

    private let queueView = QueueView()
    private var queueVisible = false
    /// Items whose completion was already handled. Change notifications are delivered
    /// asynchronously, so several can arrive after an item has finished.
    private var completed = Set<UUID>()
    var transferInBackground = false

    /// Hooks a tab's queue to the UI: progress refreshes, overwrite questions, panel reloads.
    func attach(_ tab: SessionTab) {
        tab.queue.ask = { [weak self] conflict in
            DispatchQueue.main.sync { OverwritePrompt.ask(conflict, window: self?.commander.window) }
        }
        tab.queue.onChange = { [weak self, weak tab] item in
            guard let self, let tab else { return }
            if tab === self.commander.current { self.queueView.reload() }
            if item.state.isFinished, self.completed.insert(item.id).inserted {
                self.bytesTransferred += item.progress.totalDone
                tab.local.refresh()
                tab.remote.refresh()
                if case .failed(let msg) = item.state {
                    showError(FileSystemError(.other, "Transfer of \(item.sourceDescription) failed: \(msg)"), in: self.commander.window)
                }
            }
        }
    }

    func showQueue(of tab: SessionTab) {
        if queueView.superview == nil {
            queueView.translatesAutoresizingMaskIntoConstraints = false
            commander.queueContainer.addSubview(queueView)
            NSLayoutConstraint.activate([
                queueView.topAnchor.constraint(equalTo: commander.queueContainer.topAnchor, constant: 4),
                queueView.leadingAnchor.constraint(equalTo: commander.queueContainer.leadingAnchor),
                queueView.trailingAnchor.constraint(equalTo: commander.queueContainer.trailingAnchor),
                queueView.bottomAnchor.constraint(equalTo: commander.queueContainer.bottomAnchor),
            ])
        }
        queueView.show(tab.queue)
    }

    func toggleQueueVisible() { setQueueVisible(!queueVisible) }

    func setQueueVisible(_ visible: Bool) {
        queueVisible = visible
        commander.queueHeight.constant = visible ? 150 : 0
        queueView.isHidden = !visible
    }

    // MARK: Copy / Move

    func confirmAndQueue(entries: [RemoteEntry], from src: FilePanel, to dst: FilePanel, move: Bool) {
        guard let window = commander.window else { return }
        let upload = src.backend.isLocal
        options = currentPrefs.transferOptions
        transferInBackground = currentPrefs.transferInBackgroundByDefault
        let what = entries.count == 1 ? "\"\(entries[0].name)\"" : "\(entries.count) files"
        let alert = NSAlert()
        alert.messageText = "\(move ? "Move" : "Copy") \(what) to \(upload ? "remote" : "local") directory:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let target = textField(380)
        target.stringValue = dst.path
        let preserve = NSButton(checkboxWithTitle: "Preserve timestamp", target: nil, action: nil)
        preserve.state = options.preserveTimestamp ? .on : .off
        let perms = NSButton(checkboxWithTitle: "Set permissions from local files", target: nil, action: nil)
        perms.state = options.preservePermissions ? .on : .off
        perms.isHidden = !upload
        let background = NSButton(checkboxWithTitle: "Transfer in background (add to transfer queue)", target: nil, action: nil)
        background.state = transferInBackground ? .on : .off
        let stack = NSStackView(views: [target, preserve, perms, background])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: upload ? 98 : 74)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = target
        alert.beginSheetModal(for: window) { [self] r in
            guard r == .alertFirstButtonReturn else { return }
            options.preserveTimestamp = preserve.state == .on
            options.preservePermissions = perms.state == .on
            transferInBackground = background.state == .on
            let dir = target.stringValue.trimmingCharacters(in: .whitespaces)
            if transferInBackground, let tab = commander.current {
                let targetDir = dir.isEmpty ? dst.path : dir
                let item = upload
                    ? TransferQueue.Item(upload: entries.map { URL(fileURLWithPath: RemotePath.join(src.path, $0.name)) },
                                         to: targetDir, move: move, options: options)
                    : TransferQueue.Item(download: entries, from: src.path, to: targetDir, move: move, options: options)
                tab.queue.add(item)
                setQueueVisible(true)
                return
            }
            run(entries: entries, srcDir: src.path, upload: upload, targetDir: dir.isEmpty ? dst.path : dir,
                move: move, session: sessionOf(src, dst)) {
                src.refresh()
                dst.refresh()
            }
        }
    }

    func uploadFromFinder(_ paths: [String], to panel: FilePanel) {
        guard let session = (panel.backend as? RemoteBackend)?.session else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let options = currentPrefs.transferOptions
        runForeground(title: "Uploading", session: session) { fs, ask, report in
            try TransferEngine(fs: fs, options: options, ask: ask, report: report).upload(urls, to: panel.path)
        } completion: { panel.refresh() }
    }

    private func sessionOf(_ a: FilePanel, _ b: FilePanel) -> RemoteSession? {
        ((a.backend as? RemoteBackend) ?? (b.backend as? RemoteBackend))?.session
    }

    private func run(entries: [RemoteEntry], srcDir: String, upload: Bool, targetDir: String, move: Bool,
                     session: RemoteSession?, completion: @escaping () -> Void) {
        guard let session else { return }
        let opts = options
        runForeground(title: upload ? "Uploading" : "Downloading", session: session, work: { fs, ask, report in
            let engine = TransferEngine(fs: fs, options: opts, ask: ask, report: report)
            if upload {
                let urls = entries.map { URL(fileURLWithPath: RemotePath.join(srcDir, $0.name)) }
                try engine.upload(urls, to: targetDir, deleteSource: move)
            } else {
                try engine.download(from: srcDir, entries: entries, to: URL(fileURLWithPath: targetDir), deleteSource: move)
            }
        }, completion: completion)
    }

    typealias Work = (RemoteFileSystem, @escaping (TransferEngine.Conflict) -> TransferEngine.Decision,
                      @escaping (TransferEngine.Progress) -> Bool) throws -> Void

    /// Shows WinSCP's modal progress dialog while `work` runs on the session queue.
    func runForeground(title: String, session: RemoteSession, work: @escaping Work, completion: @escaping () -> Void) {
        guard let window = commander.window else { return }
        let dialog = ProgressSheet(title: title)
        window.beginSheet(dialog.window!)
        var lastTotal: UInt64 = 0

        let ask: (TransferEngine.Conflict) -> TransferEngine.Decision = { conflict in
            DispatchQueue.main.sync { OverwritePrompt.ask(conflict, window: dialog.window) }
        }
        let report: (TransferEngine.Progress) -> Bool = { [weak self] p in
            DispatchQueue.main.async {
                dialog.update(p)
                self?.bytesTransferred += p.totalDone &- lastTotal
                lastTotal = p.totalDone
            }
            return !dialog.cancelRequested
        }
        session.perform({ fs in try work(fs, ask, report) }) { [weak self] result in
            window.endSheet(dialog.window!)
            if case .failure(let error) = result, (error as? FileSystemError)?.code != .cancelled {
                showError(error, in: window)
            }
            self?.commander.updateStatusBar()
            completion()
        }
    }

    /// Finder drop of a remote item: downloads it on the session queue into `localDir`.
    func downloadForPromise(_ entry: RemoteEntry, from dir: String, to localDir: URL, session: RemoteSession,
                            completion: @escaping (Error?) -> Void) {
        let options = currentPrefs.transferOptions
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try session.sync { fs in
                    try TransferEngine(fs: fs, options: options, ask: { _ in .overwrite }, report: { _ in true })
                        .download(from: dir, entries: [entry], to: localDir)
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    // MARK: Edit (F4)

    private var editors: [RemoteEditSession] = []

    /// Downloads to a private temp folder, opens the default editor and uploads on every save.
    /// - Parameter useEditor: true = text editor (F4), false = the file's default app.
    func editRemote(_ entry: RemoteEntry, in panel: FilePanel, useEditor: Bool = true) {
        guard let session = (panel.backend as? RemoteBackend)?.session else { return }
        let remotePath = RemotePath.join(panel.path, entry.name)
        guard RemotePath.isSafeName(entry.name) else { return }
        do {
            let dir = try RemoteEditSession.makeTempDirectory()
            let local = dir.appendingPathComponent(entry.name)
            runForeground(title: "Downloading", session: session) { fs, _, report in
                var p = TransferEngine.Progress()
                p.fileName = entry.name
                p.fileTotal = entry.size
                p.total = entry.size
                try fs.download(remotePath, to: local, offset: 0) { n in
                    p.fileDone = n
                    p.totalDone = n
                    return report(p)
                }
            } completion: { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: local.path) else { return }
                let editor = RemoteEditSession(local: local, remotePath: remotePath, session: session) { [weak self] error in
                    if let error { showError(error, in: self?.commander.window) }
                    panel.refresh()
                }
                self.editors.append(editor)
                if useEditor { EditorLauncher.edit(local, prefs: currentPrefs) } else { NSWorkspace.shared.open(local) }
            }
        } catch {
            showError(error, in: commander.window)
        }
    }

    func stopEditing() {
        editors.forEach { $0.stop() }
        editors.removeAll()
    }
}

/// Watches a downloaded copy and uploads it back when it changes.
final class RemoteEditSession {
    let local: URL
    let remotePath: String
    let session: RemoteSession
    private var source: DispatchSourceFileSystemObject?
    private var lastModified: Date?
    private let onUpload: (Error?) -> Void

    static var editRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Branding.bundleID).appendingPathComponent("edit")
    }

    static func makeTempDirectory() throws -> URL {
        let base = editRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base
    }

    /// Removes copies left behind by a crash; downloaded files should not linger on disk.
    static func removeStaleCopies() {
        try? FileManager.default.removeItem(at: editRoot)
    }

    init(local: URL, remotePath: String, session: RemoteSession, onUpload: @escaping (Error?) -> Void) {
        self.local = local
        self.remotePath = remotePath
        self.session = session
        self.onUpload = onUpload
        lastModified = modificationDate()
        watch()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: local.path))?[.modificationDate] as? Date
    }

    /// Editors often save by replacing the file, so watch the folder, not the file.
    private func watch() {
        let fd = open(local.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.changed() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func changed() {
        guard let m = modificationDate(), m != lastModified else { return }
        lastModified = m
        let local = self.local, remote = remotePath
        session.perform({ fs in try fs.upload(local, to: remote, offset: 0) { _ in true } }) { [weak self] r in
            if case .failure(let e) = r { self?.onUpload(e) } else { self?.onUpload(nil) }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
    }
}

/// WinSCP's "Confirm overwrite" question.
enum OverwritePrompt {
    static func ask(_ c: TransferEngine.Conflict, window: NSWindow?) -> TransferEngine.Decision {
        guard currentPrefs.confirmOverwrite else { return .overwrite }
        let alert = NSAlert()
        alert.messageText = "File \"\(c.name)\" already exists. Overwrite it?"
        func describe(_ size: UInt64, _ date: Date?) -> String {
            "\(Format.size(size)) bytes, \(date.map(Format.date) ?? "unknown date")"
        }
        alert.informativeText = "New:\t\(describe(c.sourceSize, c.sourceDate))\nExisting:\t\(describe(c.targetSize, c.targetDate))"
        let choices: [(String, TransferEngine.Decision)] = [
            ("Yes", .overwrite), ("No", .skip), ("Yes to All", .overwriteAll), ("No to All", .skipAll),
            ("Newer Only", .newerOnly), ("Cancel", .cancel),
        ]
        choices.forEach { alert.addButton(withTitle: $0.0) }
        let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(r) ? choices[r].1 : .cancel
    }
}

/// Modal progress dialog with file and total progress bars.
final class ProgressSheet: NSWindowController {
    private let fileLabel = label("")
    private let fileBar = NSProgressIndicator()
    private let totalBar = NSProgressIndicator()
    private let totalLabel = label("")
    private(set) var cancelRequested = false

    init(title: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        super.init(window: panel)
        [fileBar, totalBar].forEach {
            $0.isIndeterminate = false
            $0.minValue = 0
            $0.maxValue = 1
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let cancel = button("Cancel", self, #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label(title + "…"), fileLabel, fileBar, totalLabel, totalBar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -14),
            fileBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            totalBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ p: TransferEngine.Progress) {
        fileLabel.stringValue = "File: \(p.fileName)"
        fileBar.doubleValue = p.fileTotal == 0 ? 0 : Double(p.fileDone) / Double(p.fileTotal)
        totalBar.doubleValue = p.total == 0 ? 0 : Double(p.totalDone) / Double(p.total)
        totalLabel.stringValue = "\(Format.shortSize(p.totalDone)) of \(Format.shortSize(p.total)), \(p.filesDone) file(s) done"
    }

    @objc private func cancelPressed() { cancelRequested = true }
}
