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
        #expect(!RemotePath.isSafeName("a\u{0}b"))
    }
}

@Suite struct TransferQueueTests {
    @Test func processesItemsInOrderOnItsOwnConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("q-" + UUID().uuidString)
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        for d in [src, dst] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for i in 0..<3 { try Data("file \(i)".utf8).write(to: src.appendingPathComponent("f\(i).txt")) }

        var connects = 0
        let queue = TransferQueue { connects += 1; return LocalFileSystem() }
        let items = (0..<3).map { TransferQueue.Item(upload: [src.appendingPathComponent("f\($0).txt")], to: dst.path) }
        let cancelled = TransferQueue.Item(upload: [src.appendingPathComponent("f0.txt")], to: root.path)
        queue.cancel(cancelled) // cancelled before it starts: never runs
        items.forEach(queue.add)
        queue.add(cancelled)

        for _ in 0..<100 where queue.hasActiveItems { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(items.allSatisfy { $0.state == .done })
        #expect(cancelled.state == .cancelled)
        #expect(connects == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).sorted() == ["f0.txt", "f1.txt", "f2.txt"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("f0.txt").path))
        queue.removeFinished()
        #expect(queue.items.isEmpty)
    }

    @Test func failedItemsReportErrors() async throws {
        let queue = TransferQueue { LocalFileSystem() }
        let item = TransferQueue.Item(upload: [URL(fileURLWithPath: "/nonexistent/\(UUID())")], to: NSTemporaryDirectory())
        queue.add(item)
        for _ in 0..<100 where queue.hasActiveItems { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .failed = item.state else { Issue.record("expected failure, got \(item.state)"); return }
    }
}

@Suite struct TransferEngineSafetyTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("safe-" + UUID().uuidString)
    let fs = LocalFileSystem()

    func mk(_ rel: String, _ text: String? = nil) throws -> URL {
        let u = root.appendingPathComponent(rel)
        if let text {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        } else {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    @Test func moveKeepsSourceWhenSomethingWasSkipped() throws {
        let src = try mk("src/dir/a.txt", "new").deletingLastPathComponent()
        _ = try mk("src/dir/b.txt", "new")
        _ = try mk("dst/dir/a.txt", "old")
        let engine = TransferEngine(fs: fs, ask: { _ in .skip }, report: { _ in true })
        try engine.upload([src], to: root.appendingPathComponent("dst").path, deleteSource: true)
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
        #expect((try? String(contentsOf: root.appendingPathComponent("dst/dir/b.txt"), encoding: .utf8)) == "new")
    }

    @Test func fileNeverReplacesLocalFolder() throws {
        _ = try mk("remote/x", "file")
        let localFolder = try mk("local/x")
        _ = try mk("local/x/keep.txt", "keep")
        let engine = TransferEngine(fs: fs, ask: { _ in .overwrite }, report: { _ in true })
        #expect(throws: FileSystemError.self) {
            try engine.download(from: root.appendingPathComponent("remote").path, entries: try fs.list(root.appendingPathComponent("remote").path),
                                to: root.appendingPathComponent("local"))
        }
        #expect(FileManager.default.fileExists(atPath: localFolder.appendingPathComponent("keep.txt").path))
    }

    @Test func symlinkLoopsAreNotFollowed() throws {
        let dir = try mk("tree/d")
        _ = try mk("tree/d/f.txt", "x")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("loop").path, withDestinationPath: dir.path)
        let out = try mk("out")
        let engine = TransferEngine(fs: fs, ask: { _ in .overwrite }, report: { _ in true })
        try engine.upload([dir], to: out.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("d").path) == ["f.txt"])
        let back = try mk("back")
        try engine.download(from: root.appendingPathComponent("tree").path, entries: try fs.list(root.appendingPathComponent("tree").path), to: back)
        #expect(try FileManager.default.contentsOfDirectory(atPath: back.appendingPathComponent("d").path) == ["f.txt"])
    }
}
