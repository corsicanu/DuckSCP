import Foundation
import Testing
@testable import SCPCore

/// Runs against the throwaway server from scripts/test_sshd.sh. Skipped when it is not running.
private let sshDir: URL? = {
    let dir = ProcessInfo.processInfo.environment["DUCKSCP_TEST_SSH_DIR"]
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("duckscp-test-sshd")
    return FileManager.default.fileExists(atPath: dir + "/sshd.pid") ? URL(fileURLWithPath: dir) : nil
}()
private let sshPort = Int(ProcessInfo.processInfo.environment["DUCKSCP_TEST_SSH_PORT"] ?? "") ?? 2222

final class TestPrompter: ConnectionPrompter {
    var hostKeyVerdicts: [HostKeyVerdict] = []
    var decision: HostKeyDecision = .acceptAndSave
    var passphrase: String?
    var passphraseAsked = 0

    func status(_ text: String) {}
    func banner(_ text: String) {}
    func verifyHostKey(host: String, port: Int, key: HostKey, verdict: HostKeyVerdict) -> HostKeyDecision {
        hostKeyVerdicts.append(verdict)
        return decision
    }
    func askPassword(_ prompt: String) -> String? { nil }
    func askPassphrase(keyPath: String) -> String? { passphraseAsked += 1; return passphrase }

    var acceptCertificate = false
    var saveCertificate = false
    var certificateAsked = 0
    var certificateChanged: [Bool] = []
    func verifyCertificate(host: String, port: Int, fingerprint: String, problem: String, changed: Bool) -> HostKeyDecision {
        certificateAsked += 1
        certificateChanged.append(changed)
        return acceptCertificate ? (saveCertificate ? .acceptAndSave : .acceptOnce) : .reject
    }
}

/// Exercises every RemoteFileSystem operation inside a fresh folder under `parent`.
func exerciseFileSystem(_ fs: RemoteFileSystem, parent: String, expectOwner: String? = nil, attributes: Bool = true) throws {
    let base = RemotePath.join(parent, UUID().uuidString)
    try fs.makeDirectory(base)
    defer { try? RecursiveOps.delete(base, entry: RemoteEntry(name: "", kind: .directory), fs: fs) }

    let localSrc = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
    let payload = Data((0..<200_000).map { UInt8($0 % 253) })
    try payload.write(to: localSrc)
    try fs.upload(localSrc, to: base + "/it's a #file.bin", offset: 0) { _ in true }

    let listed = try fs.list(base)
    #expect(listed.map(\.name) == ["it's a #file.bin"])
    #expect(listed.first?.size == 200_000)
    if let expectOwner { #expect(listed.first?.owner == expectOwner) }

    try fs.rename(base + "/it's a #file.bin", to: base + "/b.bin")
    let st: RemoteEntry
    if attributes {
        try fs.setPermissions(base + "/b.bin", 0o640)
        let when = Date(timeIntervalSince1970: 1_500_000_000)
        try fs.setModificationDate(base + "/b.bin", when)
        st = try fs.stat(base + "/b.bin")
        if st.permissions != nil { #expect(st.permissions == 0o640) } // pyftpdlib omits unix.mode
        #expect(st.modified == when)
    } else {
        st = try fs.stat(base + "/b.bin") // WebDAV/S3: no permissions, server-set times
        #expect(st.size == 200_000 && st.kind == .file)
    }

    let localDst = FileManager.default.temporaryDirectory.appendingPathComponent("dst-\(UUID().uuidString)")
    try fs.download(base + "/b.bin", to: localDst, offset: 0) { _ in true }
    #expect(try Data(contentsOf: localDst) == payload)

    // Resume: download the rest of a partial file.
    let partial = FileManager.default.temporaryDirectory.appendingPathComponent("part-\(UUID().uuidString)")
    try payload.prefix(50_000).write(to: partial)
    try fs.download(base + "/b.bin", to: partial, offset: 50_000) { _ in true }
    #expect(try Data(contentsOf: partial) == payload)

    #expect(throws: FileSystemError.self) { try fs.stat(base + "/missing") }
    try fs.removeFile(base + "/b.bin")
    #expect(try fs.list(base).isEmpty)
}

@Suite(.enabled(if: sshDir != nil, "start scripts/test_sshd.sh"), .serialized)
struct SSHIntegrationTests {
    let dir = sshDir ?? URL(fileURLWithPath: "/")
    let hostKeys: HostKeyStore

    init() {
        hostKeys = HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID().uuidString).json"),
                                knownHostsFiles: [])
    }

    func site(_ proto: FileProtocol, key: String) -> Site {
        Site(path: "test", fileProtocol: proto, allowScpFallback: false, hostName: "127.0.0.1", port: sshPort,
             userName: NSUserName(), privateKeyPath: dir.appendingPathComponent(key).path)
    }

    func connect(_ proto: FileProtocol, key: String = "id_ed25519", prompter: TestPrompter = TestPrompter()) throws -> RemoteFileSystem {
        try Connector.connect(site: site(proto, key: key), password: nil, prompter: prompter, hostKeys: hostKeys)
    }

    func roundTrip(_ fs: RemoteFileSystem) throws {
        try exerciseFileSystem(fs, parent: dir.appendingPathComponent("home").path, expectOwner: NSUserName())
    }

    @Test func sftpRoundTrip() throws {
        let fs = try connect(.sftp)
        defer { fs.close() }
        #expect(fs.protocolName == "SFTP-3")
        #expect(try fs.homeDirectory() == NSHomeDirectory())
        try roundTrip(fs)
    }

    @Test func scpRoundTrip() throws {
        let fs = try connect(.scp)
        defer { fs.close() }
        #expect(fs.protocolName == "SCP")
        try roundTrip(fs)
    }

    @Test func sftpResumesUpload() throws {
        let fs = try connect(.sftp)
        defer { fs.close() }
        let path = dir.appendingPathComponent("home/resume-\(UUID().uuidString)").path
        defer { try? fs.removeFile(path) }
        let data = Data((0..<300_000).map { UInt8($0 % 7) })
        let half = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.prefix(100_000).write(to: half)
        try fs.upload(half, to: path, offset: 0) { _ in true }
        let full = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: full)
        try fs.upload(full, to: path, offset: 100_000) { _ in true }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    }

    @Test func hostKeyIsAskedOnceThenTrusted() throws {
        let p1 = TestPrompter()
        try connect(.sftp, prompter: p1).close()
        #expect(p1.hostKeyVerdicts == [.unknown])
        let p2 = TestPrompter()
        try connect(.sftp, prompter: p2).close()
        #expect(p2.hostKeyVerdicts.isEmpty)
    }

    @Test func changedHostKeyIsReportedAndRejectable() throws {
        try hostKeys.save(host: "127.0.0.1", port: sshPort, key: HostKey(type: "ssh-ed25519", blob: Data(repeating: 1, count: 51)))
        let p = TestPrompter()
        p.decision = .reject
        #expect(throws: FileSystemError.self) { try connect(.sftp, prompter: p) }
        guard case .changed? = p.hostKeyVerdicts.first else { Issue.record("expected changed verdict"); return }
    }

    @Test func rsaPemKey() throws { try connect(.sftp, key: "id_rsa").close() }

    @Test func encryptedOpenSSHKeyAsksPassphrase() throws {
        let p = TestPrompter()
        p.passphrase = "testpass"
        try connect(.sftp, key: "id_ed25519_enc", prompter: p).close()
        #expect(p.passphraseAsked == 1)
    }

    @Test func puttyKeys() throws {
        try connect(.sftp, key: "id_ed25519.ppk").close()
        try connect(.sftp, key: "id_rsa.ppk").close()
        let p = TestPrompter()
        p.passphrase = "testpass"
        try connect(.sftp, key: "id_ed25519_enc.ppk", prompter: p).close()
        let wrong = TestPrompter()
        wrong.passphrase = "nope"
        #expect(throws: FileSystemError.self) { try connect(.sftp, key: "id_ed25519_enc.ppk", prompter: wrong) }
    }

    @Test func wrongPortFailsCleanly() {
        var s = site(.sftp, key: "id_ed25519")
        s.port = 1
        #expect(throws: FileSystemError.self) {
            try Connector.connect(site: s, password: nil, prompter: TestPrompter(), hostKeys: hostKeys)
        }
    }
}

@Suite struct ParserTests {
    @Test func gnuFullTime() {
        let out = """
        total 12
        drwxr-xr-x  2 alice staff 4096 2024-01-02 03:04:05.123456789 +0000 .
        -rw-r--r--  1 alice staff  123 2024-01-02 03:04:05.000000000 +0100 my file.txt
        lrwxrwxrwx  1 alice staff    7 2024-01-02 03:04:05.000000000 +0000 link -> target dir
        -rwsr-xr-x  1 root  root    10 2024-01-02 03:04:05.000000000 +0000 suid
        """
        let e = LsParser.parse(out)
        #expect(e.map(\.name) == [".", "my file.txt", "link", "suid"])
        #expect(e[1].size == 123 && e[1].owner == "alice" && e[1].permissions == 0o644)
        #expect(e[1].modified == Date(timeIntervalSince1970: 1_704_161_045)) // 03:04:05 +0100
        #expect(e[2].kind == .symlink && e[2].linkTarget == "target dir")
        #expect(e[3].permissions == 0o4755)
    }

    @Test func shortDates() {
        let now = Date(timeIntervalSince1970: 1_717_200_000) // 2024-06-01
        let e = LsParser.parse("-rw-r--r-- 1 a b 5 Jan  2 03:04 x\n-rw-r--r-- 1 a b 5 Dec 25  2022 y\n-rw-r--r-- 1 a b 5 Dec 25 10:00 z", now: now)
        #expect(e.count == 3)
        #expect(e[0].modified == Date(timeIntervalSince1970: 1_704_164_640))
        #expect(e[1].modified == Date(timeIntervalSince1970: 1_671_926_400))
        #expect(e[2].modified == Date(timeIntervalSince1970: 1_703_498_400)) // Dec 2023, not Dec 2024
    }

    @Test func bsdFullTime() {
        let e = LsParser.parse("-rw-r--r--  1 alice  staff  5 Jul 14 02:40:00 2017 a b")
        #expect(e.first?.name == "a b")
        #expect(e.first?.modified == Date(timeIntervalSince1970: 1_500_000_000))
    }

    @Test func shellQuoting() {
        #expect(SCPFileSystem.quote("a b") == "'a b'")
        #expect(SCPFileSystem.quote("it's; rm -rf ~") == "'it'\\''s; rm -rf ~'")
    }

    @Test func puttyHostKeysConvert() throws {
        // RSA: e=0x10001, n=0xC5 → blob is string("ssh-rsa") mpint(e) mpint(n with leading 0)
        let rsa = try #require(HostKeyStore.puttyKey(algo: "rsa2", value: "0x10001,0xc5"))
        #expect(rsa.blob == SSHWire.string("ssh-rsa") + SSHWire.string(Data([1, 0, 1])) + SSHWire.string(Data([0, 0xc5])))
        let ed = try #require(HostKeyStore.puttyKey(algo: "ssh-ed25519", value: "0x1,0x2"))
        #expect(ed.blob.suffix(32).first == 2 && ed.blob.last == 0x80)
    }

    @Test func hashedKnownHosts() throws {
        // |1|salt|HMAC-SHA1(salt, "example.com")
        let salt = Data(repeating: 7, count: 20)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = HostKey(type: "ssh-ed25519", blob: Data([1, 2, 3]))
        let hmac = HMACHelper.sha1(key: salt, message: Data("example.com".utf8))
        try "|1|\(salt.base64EncodedString())|\(hmac.base64EncodedString()) ssh-ed25519 \(key.blob.base64EncodedString())\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let store = HostKeyStore(fileURL: url.appendingPathExtension("json"), knownHostsFiles: [url])
        #expect(store.verify(host: "example.com", port: 22, key: key) == .trusted)
        #expect(store.verify(host: "other.com", port: 22, key: key) == .unknown)
    }
}

import CryptoKit
enum HMACHelper {
    static func sha1(key: Data, message: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}

extension SSHIntegrationTests {
    @Test func rejectedPlainKeyDoesNotAskPassphrase() throws {
        // A valid key the server does not know: must fall through without passphrase prompts.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", tmp.path]
        try p.run(); p.waitUntilExit()
        let prompter = TestPrompter()
        var s = site(.sftp, key: "id_ed25519")
        s.privateKeyPath = tmp.path
        #expect(throws: FileSystemError.self) {
            try Connector.connect(site: s, password: nil, prompter: prompter, hostKeys: hostKeys)
        }
        #expect(prompter.passphraseAsked == 0)
    }
}
