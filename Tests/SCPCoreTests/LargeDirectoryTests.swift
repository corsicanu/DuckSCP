import Foundation
import Testing
@testable import SCPCore

/// WinSCP users hit trouble around 10k entries; make sure 20k list fully and quickly everywhere.
private let count = 20_000

private func makeBigDirectory(in parent: URL) throws -> URL {
    let dir = parent.appendingPathComponent("big-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<count {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(String(format: "file %05d.txt", i)).path, contents: nil)
    }
    return dir
}

private func check(_ fs: RemoteFileSystem, _ path: String, seconds limit: Double) throws {
    let start = Date()
    let entries = try fs.list(path)
    let elapsed = Date().timeIntervalSince(start)
    #expect(entries.count == count)
    #expect(Set(entries.map(\.name)).count == count)
    #expect(entries.contains { $0.name == "file 19999.txt" })
    #expect(elapsed < limit, "listing \(count) entries took \(elapsed)s")
}

@Suite(.serialized) struct LargeDirectoryTests {
    @Test func local() throws {
        let dir = try makeBigDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try check(LocalFileSystem(), dir.path, seconds: 10)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macscp-test-sshd/sshd.pid")))
    func sftpAndScp() throws {
        let sshDir = URL(fileURLWithPath: NSTemporaryDirectory() + "macscp-test-sshd")
        let dir = try makeBigDirectory(in: sshDir.appendingPathComponent("home"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostKeys = HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID()).json"), knownHostsFiles: [])
        for proto in [FileProtocol.sftp, .scp] {
            let site = Site(path: "t", fileProtocol: proto, allowScpFallback: false, hostName: "127.0.0.1", port: 2222,
                            userName: NSUserName(), privateKeyPath: sshDir.appendingPathComponent("id_ed25519").path)
            let fs = try Connector.connect(site: site, password: nil, prompter: TestPrompter(), hostKeys: hostKeys)
            defer { fs.close() }
            try check(fs, dir.path, seconds: 20)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macscp-test-ftpd/ftpd.pid")))
    func ftp() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "macscp-test-ftpd/root")
        let dir = try makeBigDirectory(in: root)
        defer { try? FileManager.default.removeItem(at: dir) }
        let site = Site(path: "f", fileProtocol: .ftp, hostName: "127.0.0.1", port: 2121, userName: "tester")
        let fs = try FTPFileSystem.connect(site: site, password: "secret", prompter: TestPrompter())
        try check(fs, "/" + dir.lastPathComponent, seconds: 30)
    }
}
