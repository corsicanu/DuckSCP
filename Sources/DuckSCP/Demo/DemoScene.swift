// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// Builds the Commander scene used for README screenshots: two example sessions,
/// a selection, and a queue with one running and one waiting transfer.
enum DemoScene {
    static func build(app: AppDelegate) {
        var web = Site(path: "Production/web-01", hostName: "web01.example.com", userName: "deploy",
                       remoteDirectory: "/var/www/html", localDirectory: "/Users/demo/Projects/web", color: 0x0088FF)
        web.ftpEncryption = .none
        let db = Site(path: "Production/db server", fileProtocol: .scp, hostName: "db.example.com", userName: "admin",
                      remoteDirectory: "/var/www/html", localDirectory: "/Users/demo/Projects/web", color: 0x8E8E93)
        let remote = DemoFileSystem.remote()
        let webSession = RemoteSession(site: web, fs: remote) { DemoFileSystem.remote() }
        let dbSession = RemoteSession(site: db, fs: DemoFileSystem.remote()) { DemoFileSystem.remote() }
        app.attach(dbSession, localBackend: DemoLocalBackend(fs: .local()))
        app.attach(webSession, localBackend: DemoLocalBackend(fs: .local()))
        guard let commander = app.commander, let tab = commander.current else { return }
        commander.window?.setContentSize(NSSize(width: 1280, height: 760))
        commander.window?.center()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            tab.local.focus()
            tab.remote.selectNames(["app.js"])
            tab.local.selectNames(["index.html", "app.js"])
            // A sparse 6 MB stand-in for app.js keeps the upload visibly in progress.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duckscp-demo-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("app.js")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            try? FileHandle(forWritingTo: file).truncate(atOffset: 6_000_000)
            // Target a folder missing from the demo tree, so no overwrite question pops up.
            let up = TransferQueue.Item(upload: [file], to: "/var/www/html/.demo-upload")
            up.displaySource = "~/Projects/web/app.js"
            up.displayTarget = "/var/www/html"
            let down = TransferQueue.Item(download: [RemoteEntry(name: "uploads", kind: .directory)], from: "/var/www/html", to: dir.path)
            down.displayTarget = "~/Downloads"
            tab.queue.add(up)
            tab.queue.add(down)
            commander.transfers.setQueueVisible(true)
        }
    }
}
