import Foundation
import Testing
@testable import SCPCore

/// LocalFileSystem stands in for the server so the engine is tested without a network.
@Suite struct TransferEngineTests {
    let root: URL
    let local: URL
    let remote: URL
    let fs = LocalFileSystem()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("te-" + UUID().uuidString)
        local = root.appendingPathComponent("local")
        remote = root.appendingPathComponent("remote")
        for d in [local, remote] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func engine(_ answer: TransferEngine.Decision = .overwrite, cancelAfter: Int = .max) -> TransferEngine {
        var calls = 0
        return TransferEngine(fs: fs, ask: { _ in answer }, report: { _ in calls += 1; return calls <= cancelAfter })
    }

    @Test func uploadsTreeAndPreservesTimestamp() throws {
        try write(local.appendingPathComponent("site/index.html"), "hi")
        try write(local.appendingPathComponent("site/css/a.css"), "body{}")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: local.appendingPathComponent("site/index.html").path)

        try engine().upload([local.appendingPathComponent("site")], to: remote.path)
        #expect(read(remote.appendingPathComponent("site/css/a.css")) == "body{}")
        let m = try FileManager.default.attributesOfItem(atPath: remote.appendingPathComponent("site/index.html").path)[.modificationDate] as? Date
        #expect(m == old)
    }

    @Test func downloadsAndMovesTree() throws {
        try write(remote.appendingPathComponent("logs/a.log"), "A")
        try write(remote.appendingPathComponent("logs/sub/b.log"), "B")
        let entries = try fs.list(remote.path)
        try engine().download(from: remote.path, entries: entries, to: local, deleteSource: true)
        #expect(read(local.appendingPathComponent("logs/sub/b.log")) == "B")
        #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("logs").path))
    }

    @Test func skipLeavesTargetAlone() throws {
        try write(local.appendingPathComponent("f.txt"), "new")
        try write(remote.appendingPathComponent("f.txt"), "old")
        try engine(.skip).upload([local.appendingPathComponent("f.txt")], to: remote.path)
        #expect(read(remote.appendingPathComponent("f.txt")) == "old")
        try engine(.overwrite).upload([local.appendingPathComponent("f.txt")], to: remote.path)
        #expect(read(remote.appendingPathComponent("f.txt")) == "new")
    }

    @Test func cancelDecisionAborts() throws {
        try write(local.appendingPathComponent("f.txt"), "new")
        try write(remote.appendingPathComponent("f.txt"), "old")
        #expect(throws: FileSystemError.cancelled) {
            try engine(.cancel).upload([local.appendingPathComponent("f.txt")], to: remote.path)
        }
        #expect(read(remote.appendingPathComponent("f.txt")) == "old")
    }

    @Test func largeFilesGoThroughFilepartAndResume() throws {
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        try big.write(to: remote.appendingPathComponent("big.bin"))
        // Simulate an interrupted earlier download.
        try big.prefix(120_000).write(to: local.appendingPathComponent("big.bin.filepart"))
        let entries = try fs.list(remote.path)
        try engine().download(from: remote.path, entries: entries, to: local)
        #expect(try Data(contentsOf: local.appendingPathComponent("big.bin")) == big)
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("big.bin.filepart").path))
    }

    @Test func refusesServerNamesThatEscapeTarget() throws {
        let evil = RemoteEntry(name: "../escape.txt", kind: .file, size: 1)
        #expect(throws: FileSystemError.self) { try engine().download(from: remote.path, entries: [evil], to: local) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
    }

    @Test func progressCancelStopsTransfer() throws {
        try Data(count: 600_000).write(to: local.appendingPathComponent("z.bin"))
        #expect(throws: FileSystemError.cancelled) {
            try engine(cancelAfter: 1).upload([local.appendingPathComponent("z.bin")], to: remote.path)
        }
        #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("z.bin").path))
    }

    @Test func rightsString() {
        #expect(RemoteEntry.rights(0o755) == "rwxr-xr-x")
        #expect(RemoteEntry.rights(0o4755) == "rwsr-xr-x")
        #expect(RemoteEntry.rights(0o1777) == "rwxrwxrwt")
        #expect(RemoteEntry.rights(0o2640) == "rw-r-S---")
    }

    @Test func remotePathHelpers() {
        #expect(RemotePath.parent("/a/b/") == "/a")
        #expect(RemotePath.parent("/a") == "/")
        #expect(RemotePath.join("/", "x") == "/x")
        #expect(!RemotePath.isSafeName("..") && !RemotePath.isSafeName("a/b") && RemotePath.isSafeName("a b"))
    }
}
