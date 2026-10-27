import Foundation
import Testing
@testable import SCPCore

@Suite struct SynchronizerTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + UUID().uuidString)
    var local: URL { root.appendingPathComponent("local") }
    var remote: URL { root.appendingPathComponent("remote") }
    let old = Date(timeIntervalSince1970: 1_600_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)

    func file(_ base: URL, _ rel: String, _ text: String, _ date: Date) throws {
        let u = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
    }

    func read(_ base: URL, _ rel: String) -> String? { try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8) }

    func setUp() throws {
        try file(local, "same.txt", "same", old)
        try file(remote, "same.txt", "same", old)
        try file(local, "newer-local.txt", "L2", new)
        try file(remote, "newer-local.txt", "L1", old)
        try file(local, "newer-remote.txt", "R1", old)
        try file(remote, "newer-remote.txt", "R2", new)
        try file(local, "only-local/a.txt", "a", old)
        try file(remote, "only-remote.txt", "r", old)
        try file(local, "sub/deep.txt", "d2", new)
        try file(remote, "sub/deep.txt", "d1", old)
        try file(local, "skip.tmp", "x", old)
    }

    func sync(_ dir: Synchronizer.Direction, delete: Bool = false) -> Synchronizer {
        var o = Synchronizer.Options()
        o.direction = dir
        o.deleteObsolete = delete
        o.exclude = FileMask("*.tmp")
        return Synchronizer(fs: LocalFileSystem(), options: o)
    }

    @Test func bothDirectionsPlan() throws {
        try setUp()
        let plan = try sync(.both).plan(localRoot: local, remoteRoot: remote.path)
        let summary = plan.map { "\($0.kind.rawValue) \($0.relativePath)" }.sorted()
        #expect(summary == ["download newer-remote.txt", "download only-remote.txt", "upload newer-local.txt",
                            "upload only-local", "upload sub/deep.txt"])
    }

    @Test func bothDirectionsRun() throws {
        try setUp()
        let s = sync(.both)
        try s.run(try s.plan(localRoot: local, remoteRoot: remote.path), localRoot: local, remoteRoot: remote.path,
                  transfer: .init(), report: { _ in true })
        #expect(read(remote, "newer-local.txt") == "L2" && read(local, "newer-remote.txt") == "R2")
        #expect(read(remote, "only-local/a.txt") == "a" && read(local, "only-remote.txt") == "r")
        #expect(read(remote, "sub/deep.txt") == "d2" && read(remote, "skip.tmp") == nil)
        #expect(try sync(.both).plan(localRoot: local, remoteRoot: remote.path).isEmpty) // now in sync
    }

    @Test func mirrorRemoteDeletesObsolete() throws {
        try setUp()
        let s = sync(.remote, delete: true)
        let plan = try s.plan(localRoot: local, remoteRoot: remote.path)
        #expect(plan.contains { $0.kind == .deleteRemote && $0.relativePath == "only-remote.txt" })
        // Remote is updated from local even where remote is newer.
        #expect(plan.contains { $0.kind == .upload && $0.relativePath == "newer-remote.txt" })
        try s.run(plan, localRoot: local, remoteRoot: remote.path, transfer: .init(), report: { _ in true })
        #expect(read(remote, "only-remote.txt") == nil && read(remote, "newer-remote.txt") == "R1")
    }

    @Test func mirrorLocalWithoutDeleteKeepsExtraFiles() throws {
        try setUp()
        let plan = try sync(.local).plan(localRoot: local, remoteRoot: remote.path)
        #expect(!plan.contains { $0.kind == .deleteLocal })
        #expect(plan.contains { $0.kind == .download && $0.relativePath == "newer-local.txt" })
    }

    @Test func fileVsFolderIsAConflict() throws {
        try file(local, "x", "file", old)
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("x"), withIntermediateDirectories: true)
        let plan = try sync(.both).plan(localRoot: local, remoteRoot: remote.path)
        #expect(plan.map(\.kind) == [.conflict])
    }

    @Test func sizeCriteria() throws {
        try file(local, "f", "abc", old)
        try file(remote, "f", "abcd", old)
        var o = Synchronizer.Options()
        o.direction = .remote
        o.criteria = .size
        #expect(try Synchronizer(fs: LocalFileSystem(), options: o).plan(localRoot: local, remoteRoot: remote.path).map(\.kind) == [.upload])
        o.criteria = .time
        #expect(try Synchronizer(fs: LocalFileSystem(), options: o).plan(localRoot: local, remoteRoot: remote.path).isEmpty)
    }
}
