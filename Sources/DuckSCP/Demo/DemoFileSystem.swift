// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SCPCore

/// In-memory example file trees for screenshots and demos (`--demo-screenshot`),
/// so no real user names or folders ever appear in published images.
final class DemoFileSystem: RemoteFileSystem {
    private var tree: [String: [RemoteEntry]]
    let home: String
    let name: String
    /// Simulated upload rate (bytes/s) so the queue shows a transfer in progress.
    var uploadRate: Double = 2_100_000

    init(name: String, home: String, tree: [String: [RemoteEntry]]) {
        self.name = name
        self.home = home
        self.tree = tree
    }

    var protocolName: String { name }
    var supportsResume: Bool { false }
    func close() {}
    func homeDirectory() throws -> String { home }

    func list(_ path: String) throws -> [RemoteEntry] {
        guard let e = tree[path] else { throw FileSystemError(.notFound, "No such file or directory: \(path)") }
        return e
    }

    func stat(_ path: String) throws -> RemoteEntry {
        guard let e = tree[RemotePath.parent(path)]?.first(where: { $0.name == RemotePath.name(path) }) else {
            throw FileSystemError(.notFound, "No such file or directory: \(path)")
        }
        return e
    }

    func makeDirectory(_ path: String) throws {}
    func removeFile(_ path: String) throws {}
    func removeDirectory(_ path: String) throws {}
    func rename(_ from: String, to: String) throws {}
    func setPermissions(_ path: String, _ mode: UInt32) throws {}
    func setModificationDate(_ path: String, _ date: Date) throws {}
    func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {}

    func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64) ?? 0
        var done: UInt64 = 0
        while done < size {
            Thread.sleep(forTimeInterval: 0.1)
            done = min(size, done + UInt64(uploadRate / 10))
            if !progress(done) { throw FileSystemError.cancelled }
        }
    }

    // MARK: Example trees

    static func remote() -> DemoFileSystem {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        func dir(_ n: String, _ d: Date, _ p: UInt32 = 0o755) -> RemoteEntry {
            RemoteEntry(name: n, kind: .directory, modified: d, permissions: p, owner: "deploy", group: "www-data")
        }
        func file(_ n: String, _ s: UInt64, _ d: Date, _ p: UInt32 = 0o644) -> RemoteEntry {
            RemoteEntry(name: n, kind: .file, size: s, modified: d, permissions: p, owner: "deploy", group: "www-data")
        }
        let html: [RemoteEntry] = [
            dir("assets", ago(1)), dir("css", ago(30)), dir("uploads", ago(2), 0o775),
            file("index.html", 13_312, ago(12)), file("app.js", 212_992, ago(12)), file("404.html", 4_210, ago(400)),
            file(".htaccess", 512, ago(1300)), file("favicon.ico", 15_086, ago(2100)), file("robots.txt", 68, ago(1350)),
            file("sitemap.xml", 9_870, ago(52)),
        ]
        return DemoFileSystem(name: "SFTP-3", home: "/var/www/html", tree: [
            "/var/www/html": html, "/var/www": [dir("html", ago(2))], "/var": [dir("www", ago(900))], "/": [dir("var", ago(5000))],
            "/var/www/html/assets": [file("hero.webp", 184_320, ago(1)), file("duck.svg", 3_071, ago(1))],
            "/var/www/html/css": [file("site.css", 48_211, ago(30))],
            "/var/www/html/uploads": [file("report-q3.pdf", 1_482_112, ago(2))],
        ])
    }

    static func local() -> DemoFileSystem {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        func dir(_ n: String, _ d: Date) -> RemoteEntry { RemoteEntry(name: n, kind: .directory, modified: d, permissions: 0o755) }
        func file(_ n: String, _ s: UInt64, _ d: Date) -> RemoteEntry { RemoteEntry(name: n, kind: .file, size: s, modified: d, permissions: 0o644) }
        let web: [RemoteEntry] = [
            dir("assets", ago(1.2)), dir("css", ago(16)), file("index.html", 14_336, ago(0.5)), file("app.js", 217_088, ago(0.6)),
            file("404.html", 4_210, ago(400)), file("logo.svg", 3_071, ago(380)), file("robots.txt", 68, ago(1350)),
            file("deploy.sh", 1_204, ago(150)), file("package.json", 812, ago(150)), file("README.md", 2_310, ago(200)),
        ]
        return DemoFileSystem(name: "Local", home: "/Users/demo", tree: [
            "/Users/demo/Projects/web": web, "/Users/demo/Projects": [dir("web", ago(0.5))],
            "/Users/demo": [dir("Projects", ago(3)), dir("Downloads", ago(5))], "/Users": [dir("demo", ago(3))],
            "/": [dir("Users", ago(3000))], "/Users/demo/Projects/web/assets": [], "/Users/demo/Projects/web/css": [],
            "/Users/demo/Downloads": [],
        ])
    }
}

/// Local-panel backend over a demo tree (shows "~" for /Users/demo).
final class DemoLocalBackend: PanelBackend {
    let fs: DemoFileSystem
    init(fs: DemoFileSystem) { self.fs = fs }
    var isLocal: Bool { true }
    var homeDirectory: String { fs.home }
    func list(_ path: String, completion: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        let r = Result { try fs.list(path) }
        DispatchQueue.main.async { completion(r) }
    }
}
