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
                queueView.topAnchor.constraint(equalTo: commander.queueContainer.topAnchor),
                queueView.leadingAnchor.constraint(equalTo: commander.queueContainer.leadingAnchor),
                queueView.trailingAnchor.constraint(equalTo: commander.queueContainer.trailingAnchor),
                queueView.bottomAnchor.constraint(equalTo: commander.queueContainer.bottomAnchor),
            ])
        }
        queueView.show(tab.queue)
    }

    /// Toolbar "Queue": shows/hides the list and remembers the choice.
    func toggleQueueVisible() {
        setQueueVisible(!queueVisible)
        try? (NSApp.delegate as? AppDelegate)?.prefs.update { $0.showQueue = queueVisible }
    }

    func setQueueVisible(_ visible: Bool) {
        queueVisible = visible
        commander.queueHeight.constant = visible ? 110 : 0
        queueView.isHidden = !visible
    }

    // MARK: Copy / Move

    struct TransferChoice {
        var targetDir: String
        var options: TransferEngine.Options
        var background: Bool
    }

    /// WinSCP's Copy/Upload dialog: the target folder is an editable combo box offering
    /// the folder you dropped on (or the other panel's folder) plus the global history
    /// of earlier targets. Remote paths are not checked; local ones can be browsed.
    func promptTarget(title: String, defaultTarget: String, upload: Bool, completion: @escaping (TransferChoice) -> Void) {
        guard let window = commander.window else { return }
        var options = currentPrefs.transferOptions
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: upload ? "Upload" : "Download")
        alert.addButton(withTitle: "Cancel")

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        combo.completes = true
        combo.numberOfVisibleItems = 12
        var seen = Set<String>()
        let history = upload ? currentPrefs.remoteTargetHistory : currentPrefs.localTargetHistory
        for p in [defaultTarget] + history where seen.insert(p).inserted { combo.addItem(withObjectValue: p) }
        combo.stringValue = defaultTarget
        combo.toolTip = "Type a path or pick a recent one. Recent targets are shared by all sites."
        combo.setAccessibilityLabel("Target folder")

        var row: [NSView] = [combo]
        if !upload {
            let browse = NSButton(title: "Choose…", target: nil, action: nil)
            browse.bezelStyle = .rounded
            browseHandler = { [weak window] in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = URL(fileURLWithPath: combo.stringValue)
                if panel.runModal() == .OK, let url = panel.url { combo.stringValue = url.path }
                _ = window
            }
            browse.target = self
            browse.action = #selector(browseClicked)
            row.append(browse)
        }
        let targetRow = NSStackView(views: row)
        let preserve = NSButton(checkboxWithTitle: "Preserve timestamp", target: nil, action: nil)
        preserve.state = options.preserveTimestamp ? .on : .off
        let perms = NSButton(checkboxWithTitle: "Set permissions from local files", target: nil, action: nil)
        perms.state = options.preservePermissions ? .on : .off
        perms.isHidden = !upload
        let background = NSButton(checkboxWithTitle: "Transfer in background (add to transfer queue)", target: nil, action: nil)
        background.state = currentPrefs.transferInBackgroundByDefault ? .on : .off
        let stack = NSStackView(views: [label("Target folder:"), targetRow, preserve, perms, background])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: upload ? 420 : 520, height: upload ? 124 : 100)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = combo
        alert.beginSheetModal(for: window) { [self] r in
            browseHandler = nil
            guard r == .alertFirstButtonReturn else { return }
            let dir = combo.stringValue.trimmingCharacters(in: .whitespaces)
            let target = dir.isEmpty ? defaultTarget : dir
            options.preserveTimestamp = preserve.state == .on
            options.preservePermissions = perms.state == .on
            try? (NSApp.delegate as? AppDelegate)?.prefs.update {
                if upload { Preferences.remember(target, in: &$0.remoteTargetHistory) }
                else { Preferences.remember(target, in: &$0.localTargetHistory) }
            }
            completion(TransferChoice(targetDir: target, options: options, background: background.state == .on))
        }
    }

    private var browseHandler: (() -> Void)?
    @objc private func browseClicked() { browseHandler?() }

    /// F5/F6 and drags between the panels.
    func confirmAndQueue(entries: [RemoteEntry], from src: FilePanel, to dst: FilePanel, move: Bool, defaultTarget: String? = nil) {
        let upload = src.backend.isLocal
        let what = entries.count == 1 ? "\"\(entries[0].name)\"" : "\(entries.count) items"
        promptTarget(title: "\(move ? "Move" : upload ? "Upload" : "Download") \(what) to:", defaultTarget: defaultTarget ?? dst.path,
                     upload: upload) { [self] choice in
            options = choice.options
            if choice.background, let tab = commander.current {
                let item = upload
                    ? TransferQueue.Item(upload: entries.map { URL(fileURLWithPath: RemotePath.join(src.path, $0.name)) },
                                         to: choice.targetDir, move: move, options: choice.options)
                    : TransferQueue.Item(download: entries, from: src.path, to: choice.targetDir, move: move, options: choice.options)
                tab.queue.add(item)
                setQueueVisible(true)
                return
            }
            run(entries: entries, srcDir: src.path, upload: upload, targetDir: choice.targetDir, move: move,
                session: sessionOf(src, dst)) {
                src.refresh()
                dst.refresh()
            }
        }
    }

    /// Files dropped from Finder onto the remote panel: asks where to put them first.
    func uploadFromFinder(_ paths: [String], to panel: FilePanel, defaultTarget: String) {
        guard let session = (panel.backend as? RemoteBackend)?.session, let tab = commander.current else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let what = urls.count == 1 ? "\"\(urls[0].lastPathComponent)\"" : "\(urls.count) items"
        promptTarget(title: "Upload \(what) to:", defaultTarget: defaultTarget, upload: true) { [self] choice in
            if choice.background {
                tab.queue.add(TransferQueue.Item(upload: urls, to: choice.targetDir, options: choice.options))
                setQueueVisible(true)
                return
            }
            runForeground(title: "Uploading", session: session) { fs, ask, report in
                try TransferEngine(fs: fs, options: choice.options, ask: ask, report: report).upload(urls, to: choice.targetDir)
            } completion: { panel.refresh() }
        }
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
                guard let tab = self.commander.tabs.first(where: { $0.remote === panel }) else { return }
                let editor = RemoteEditSession(local: local, remotePath: remotePath, queue: tab.queue) { [weak self] error in
                    if let error {
                        showError(FileSystemError(.other, "Uploading \(entry.name) failed: \(error). Save again to retry."), in: self?.commander.window)
                    } else {
                        self?.commander.flashStatus("Uploaded \(entry.name)")
                    }
                }
                self.editors.append(editor)
                // Snapshot/test runs never launch the user's editor.
                if (NSApp.delegate as? AppDelegate)?.isSnapshotMode == true { return }
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

/// A remote file open in an editor: its private local copy and the watcher that
/// uploads every save (see RemoteFileEditor).
final class RemoteEditSession {
    let local: URL
    let remotePath: String

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

    private let editor: RemoteFileEditor

    /// Each save becomes a queue item, so it shows in Transfers like any upload (WinSCP does
    /// the same) and runs on the queue's own connection.
    init(local: URL, remotePath: String, queue: TransferQueue, onUpload: @escaping (Error?) -> Void) {
        self.local = local
        self.remotePath = remotePath
        let name = RemotePath.name(remotePath)
        editor = RemoteFileEditor(local: local, remotePath: remotePath, upload: { local, remote, done in
            var options = currentPrefs.transferOptions
            options.alwaysOverwrite = true      // saving is the user's decision to replace it
            options.preservePermissions = false // keep the server's permissions
            options.exclude = FileMask("")
            let item = TransferQueue.Item(upload: [local], to: RemotePath.parent(remote), options: options)
            item.displaySource = "\(name) (edited)"
            item.displayTarget = RemotePath.parent(remote)
            item.onFinished = { state in
                switch state {
                case .done: done(nil)
                case .failed(let msg): done(FileSystemError(.other, msg))
                default: done(FileSystemError.cancelled)
                }
            }
            DispatchQueue.main.async { queue.add(item) }
        }, onUploaded: onUpload)
    }

    func stop() { editor.stop() }
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
