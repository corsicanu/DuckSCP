import Foundation
import Testing
@testable import SCPCore

/// Local file system that fails with a connection error a given number of times.
final class FlakyFileSystem: RemoteFileSystem {
    let inner = LocalFileSystem()
    var failuresLeft: Int
    var closed = false
    init(failures: Int) { failuresLeft = failures }

    private func maybeFail() throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw FileSystemError(.connection, "Connection lost: simulated")
        }
    }

    var protocolName: String { "Flaky" }
    var supportsResume: Bool { true }
    func close() { closed = true }
    func homeDirectory() throws -> String { try inner.homeDirectory() }
    func list(_ path: String) throws -> [RemoteEntry] { try maybeFail(); return try inner.list(path) }
    func stat(_ path: String) throws -> RemoteEntry { try inner.stat(path) }
    func makeDirectory(_ path: String) throws { try inner.makeDirectory(path) }
    func removeFile(_ path: String) throws { try inner.removeFile(path) }
    func removeDirectory(_ path: String) throws { try inner.removeDirectory(path) }
    func rename(_ from: String, to: String) throws { try inner.rename(from, to: to) }
    func setPermissions(_ path: String, _ mode: UInt32) throws { try inner.setPermissions(path, mode) }
    func setModificationDate(_ path: String, _ date: Date) throws { try inner.setModificationDate(path, date) }
    func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try inner.download(path, to: local, offset: offset, progress: progress)
    }
    func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try maybeFail()
        try inner.upload(local, to: path, offset: offset, progress: progress)
    }
}

@Suite struct ReconnectTests {
    func policy(_ enabled: Bool) -> ReconnectPolicy {
        var p = ReconnectPolicy()
        p.enabled = enabled
        p.delay = 0
        return p
    }

    @Test func sessionReconnectsAndRetries() throws {
        let dead = FlakyFileSystem(failures: 1)
        var connects = 0
        let session = RemoteSession(site: Site(path: "x"), fs: dead) { connects += 1; return FlakyFileSystem(failures: 0) }
        session.reconnectPolicy = { policy(true) }
        _ = try session.sync { try $0.list(NSTemporaryDirectory()) } // must not throw
        #expect(connects == 1 && dead.closed)
    }

    @Test func disabledReconnectSurfacesError() {
        let session = RemoteSession(site: Site(path: "x"), fs: FlakyFileSystem(failures: 1)) { FlakyFileSystem(failures: 0) }
        session.reconnectPolicy = { policy(false) }
        #expect(throws: FileSystemError.self) { try session.sync { try $0.list(NSTemporaryDirectory()) } }
    }

    @Test func givesUpAfterAttempts() {
        var p = policy(true)
        p.attempts = 2
        var tries = 0
        let fs = p.reconnect({ tries += 1; throw FileSystemError(.connection, "down") }, status: { _ in })
        #expect(fs == nil && tries == 2)
    }

    @Test func queueRetriesItemOnFreshConnection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rq-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: f)
        var connects = 0
        let queue = TransferQueue {
            connects += 1
            return FlakyFileSystem(failures: connects == 1 ? 1 : 0) // first connection drops
        }
        queue.reconnectPolicy = { policy(true) }
        let item = TransferQueue.Item(upload: [f], to: dir.appendingPathComponent("out").path)
        queue.add(item)
        for _ in 0..<100 where queue.hasActiveItems { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(item.state == .done && connects == 2)
    }

    @Test func queueStopsRetryingFlappingServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rq-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: f)
        let queue = TransferQueue { FlakyFileSystem(failures: 1) } // every connection drops
        queue.reconnectPolicy = { policy(true) }
        let item = TransferQueue.Item(upload: [f], to: dir.path + "/x")
        queue.add(item)
        for _ in 0..<200 where queue.hasActiveItems { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .failed = item.state else { Issue.record("expected failure, got \(item.state)"); return }
    }
}
