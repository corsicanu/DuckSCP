// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SCPCore

/// Saves the way Sublime Text does by default (atomic_save: false): rewrite in place.
func saveInPlace(_ url: URL, _ text: String) throws {
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: 0)
    try h.write(contentsOf: Data(text.utf8))
    try h.close()
}

/// Saves the way TextEdit/BBEdit (and Sublime with atomic_save: true) do: temp file + rename.
private func saveAtomically(_ url: URL, _ text: String) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
}

final class Uploads {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Suite(.serialized) struct RemoteFileEditorTests {
    func makeCopy(_ text: String = "v1") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("index.html")
        try Data(text.utf8).write(to: f)
        return f
    }

    func editor(_ f: URL, _ uploads: Uploads, queue: DispatchQueue) -> RemoteFileEditor {
        RemoteFileEditor(local: f, remotePath: "/srv/index.html", queue: queue, debounce: 0.2, upload: { local, _, done in
            uploads.add((try? String(contentsOf: local, encoding: .utf8)) ?? "")
            done(nil)
        }, onUploaded: { _ in })
    }

    @Test func inPlaceSaveUploads() async throws {
        let f = try makeCopy()
        let uploads = Uploads()
        let ed = editor(f, uploads, queue: DispatchQueue(label: "t1"))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(uploads.all.isEmpty) // opening alone uploads nothing
        try saveInPlace(f, "v2 saved in place")
        await waitUntil { uploads.all.count == 1 }
        #expect(uploads.all == ["v2 saved in place"])
        ed.stop()
    }

    @Test func atomicSaveUploadsAndKeepsWatching() async throws {
        let f = try makeCopy()
        let uploads = Uploads()
        let ed = editor(f, uploads, queue: DispatchQueue(label: "t2"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try saveAtomically(f, "v2 atomic")
        await waitUntil { uploads.all.count == 1 }
        // After a replace, the next in-place save must still be seen.
        try saveInPlace(f, "v3 in place")
        await waitUntil { uploads.all.count == 2 }
        #expect(uploads.all == ["v2 atomic", "v3 in place"])
        ed.stop()
    }

    @Test func burstOfSavesUploadsLatestContent() async throws {
        let f = try makeCopy()
        let uploads = Uploads()
        let ed = editor(f, uploads, queue: DispatchQueue(label: "t3"))
        try await Task.sleep(nanoseconds: 300_000_000)
        for i in 1...5 { try saveInPlace(f, "rapid \(i)") }
        await waitUntil { uploads.all.last == "rapid 5" }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(uploads.all.last == "rapid 5")
        #expect(uploads.all.count <= 2) // debounced, not one upload per write
        ed.stop()
    }

    @Test func stopEndsWatchingAndRemovesCopy() async throws {
        let f = try makeCopy()
        let uploads = Uploads()
        let ed = editor(f, uploads, queue: DispatchQueue(label: "t4"))
        ed.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!FileManager.default.fileExists(atPath: f.deletingLastPathComponent().path))
        #expect(uploads.all.isEmpty)
    }
}

/// End to end against the throwaway sshd (scripts/test_sshd.sh): download, edit like
/// Sublime, and check that the server copy changes.
@Suite(.enabled(if: FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "duckscp-test-sshd/sshd.pid"),
                "start scripts/test_sshd.sh"), .serialized)
struct RemoteEditIntegrationTests {
    @Test func sublimeStyleSaveReachesServer() async throws {
        let sshDir = URL(fileURLWithPath: NSTemporaryDirectory() + "duckscp-test-sshd")
        let remoteDir = sshDir.appendingPathComponent("home/edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: remoteDir) }
        let remoteFile = remoteDir.appendingPathComponent("site.conf")
        try Data("listen 80;\n".utf8).write(to: remoteFile)

        let site = Site(path: "dummy", fileProtocol: .sftp, allowScpFallback: false, hostName: "127.0.0.1", port: 2222,
                        userName: NSUserName(), privateKeyPath: sshDir.appendingPathComponent("id_ed25519").path)
        let keys = HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID()).json"), knownHostsFiles: [])
        let fs = try Connector.connect(site: site, password: nil, prompter: TestPrompter(), hostKeys: keys)
        let session = RemoteSession(site: site, fs: fs) { try Connector.connect(site: site, password: nil, prompter: TestPrompter(), hostKeys: keys) }
        defer { session.close() }

        let copyDir = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID())")
        try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
        let copy = copyDir.appendingPathComponent("site.conf")
        try session.sync { try $0.download(remoteFile.path, to: copy, offset: 0) { _ in true } }

        let results = Uploads()
        let editor = RemoteFileEditor(local: copy, remotePath: remoteFile.path, queue: DispatchQueue(label: "e2e"), debounce: 0.2,
            upload: { local, remote, done in
                session.perform({ fs in try fs.upload(local, to: remote, offset: 0) { _ in true } }) { r in
                    if case .failure(let e) = r { done(e) } else { done(nil) }
                }
            }, onUploaded: { error in results.add(error.map { "\($0)" } ?? "ok") })
        defer { editor.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        try saveInPlace(copy, "listen 8080;\n")
        await waitUntil { results.all.count == 1 }
        #expect(results.all == ["ok"])
        #expect(try String(contentsOf: remoteFile, encoding: .utf8) == "listen 8080;\n")

        try saveAtomically(copy, "listen 8443 ssl;\n")
        await waitUntil { results.all.count == 2 }
        #expect(try String(contentsOf: remoteFile, encoding: .utf8) == "listen 8443 ssl;\n")
    }
}

/// Editor saves go through the transfer queue (so they are listed in Transfers),
/// overwrite without asking, and report back through onFinished.
@Suite(.enabled(if: FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "duckscp-test-sshd/sshd.pid"),
                "start scripts/test_sshd.sh"), .serialized)
struct RemoteEditQueueTests {
    @Test func savesAreQueuedAndReachServer() async throws {
        let sshDir = URL(fileURLWithPath: NSTemporaryDirectory() + "duckscp-test-sshd")
        let remoteDir = sshDir.appendingPathComponent("home/editq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: remoteDir) }
        let remoteFile = remoteDir.appendingPathComponent("app.conf")
        try Data("old\n".utf8).write(to: remoteFile)

        let site = Site(path: "dummy", fileProtocol: .sftp, allowScpFallback: false, hostName: "127.0.0.1", port: 2222,
                        userName: NSUserName(), privateKeyPath: sshDir.appendingPathComponent("id_ed25519").path)
        let keys = HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID()).json"), knownHostsFiles: [])
        let queue = TransferQueue { try Connector.connect(site: site, password: nil, prompter: TestPrompter(), hostKeys: keys) }
        var asked = 0
        queue.ask = { _ in asked += 1; return .skip } // must never be consulted for editor saves
        defer { queue.close() }

        let copyDir = FileManager.default.temporaryDirectory.appendingPathComponent("qcopy-\(UUID())")
        try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
        let copy = copyDir.appendingPathComponent("app.conf")
        try Data("old\n".utf8).write(to: copy)

        let results = Uploads()
        let editor = RemoteFileEditor(local: copy, remotePath: remoteFile.path, queue: DispatchQueue(label: "q"), debounce: 0.2,
            upload: { local, remote, done in
                var o = TransferEngine.Options()
                o.alwaysOverwrite = true
                let item = TransferQueue.Item(upload: [local], to: RemotePath.parent(remote), options: o)
                item.displaySource = "app.conf (edited)"
                item.onFinished = { state in done(state == .done ? nil : FileSystemError(.other, "\(state)")) }
                queue.add(item)
            }, onUploaded: { error in results.add(error.map { "\($0)" } ?? "ok") })
        defer { editor.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        try saveInPlace(copy, "new from sublime\n")
        await waitUntil(10) { results.all.count == 1 }
        #expect(results.all == ["ok"])
        #expect(asked == 0)
        #expect(try String(contentsOf: remoteFile, encoding: .utf8) == "new from sublime\n")
        #expect(queue.items.map(\.sourceDescription) == ["app.conf (edited)"])
        #expect(queue.items.first?.state == .done)
    }
}

@Suite struct QueueCallbackTests {
    @Test func onFinishedFiresForCancelledWaitingItem() {
        let queue = TransferQueue { LocalFileSystem() }
        let item = TransferQueue.Item(upload: [URL(fileURLWithPath: "/nonexistent")], to: "/tmp")
        var finished: TransferQueue.State?
        item.onFinished = { finished = $0 }
        queue.cancel(item)
        #expect(finished == .cancelled)
    }
}
