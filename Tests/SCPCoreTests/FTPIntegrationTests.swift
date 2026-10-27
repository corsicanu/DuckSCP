// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SCPCore

/// Runs against scripts/test_ftpd.sh (pyftpdlib). Skipped when it is not running.
private let ftpRunning: Bool = {
    let dir = ProcessInfo.processInfo.environment["DUCKSCP_TEST_FTP_DIR"]
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("duckscp-test-ftpd")
    return FileManager.default.fileExists(atPath: dir + "/ftpd.pid")
}()

@Suite(.enabled(if: ftpRunning, "start scripts/test_ftpd.sh"), .serialized)
struct FTPIntegrationTests {
    func site(_ enc: FtpEncryption = .none, passive: Bool = true) -> Site {
        Site(path: "ftp", fileProtocol: .ftp, ftpEncryption: enc, ftpPassive: passive, hostName: "127.0.0.1", port: 2121, userName: "tester")
    }

    @Test func plainFTP() throws {
        let fs = try Connector.connect(site: site(), password: "secret", prompter: TestPrompter(),
                                       hostKeys: HostKeyStore(fileURL: URL(fileURLWithPath: "/dev/null"), knownHostsFiles: []))
        #expect(fs.protocolName == "FTP")
        #expect(try fs.homeDirectory() == "/")
        try exerciseFileSystem(fs, parent: "/")
    }

    @Test func activeMode() throws {
        let fs = try FTPFileSystem.connect(site: site(passive: false), password: "secret", prompter: TestPrompter())
        #expect(try fs.list("/").allSatisfy { !$0.name.isEmpty })
    }

    @Test func explicitTLSAsksAboutSelfSignedCertificate() throws {
        let refuse = TestPrompter()
        #expect(throws: FileSystemError.self) { try FTPFileSystem.connect(site: site(.explicitTLS), password: "secret", prompter: refuse) }
        #expect(refuse.certificateAsked == 1)

        let accept = TestPrompter()
        accept.acceptCertificate = true
        let fs = try FTPFileSystem.connect(site: site(.explicitTLS), password: "secret", prompter: accept)
        #expect(fs.protocolName == "FTPS")
        try exerciseFileSystem(fs, parent: "/")
    }

    @Test func wrongPasswordAsksAgainThenFails() {
        let p = TestPrompter() // askPassword returns nil → cancelled
        #expect(throws: FileSystemError.self) { try FTPFileSystem.connect(site: site(), password: "wrong", prompter: p) }
    }

    @Test func rejectsCommandInjectionInNames() throws {
        let fs = try FTPFileSystem.connect(site: site(), password: "secret", prompter: TestPrompter())
        #expect(throws: FileSystemError.self) { try fs.makeDirectory("/x\r\nDELE /important") }
    }
}

@Suite struct FTPParserTests {
    @Test func mlsd() {
        let e = FTPListParser.parseMLSD("""
        type=cdir;modify=20240102030405; .
        type=dir;modify=20240102030405;unix.mode=0755; my dir
        type=file;size=42;modify=20240102030405.123;UNIX.mode=0644;UNIX.owner=bob; a;b.txt
        """)
        #expect(e.map(\.name) == ["my dir", "a;b.txt"])
        #expect(e[1].size == 42 && e[1].permissions == 0o644 && e[1].owner == "bob")
        #expect(e[1].modified == Date(timeIntervalSince1970: 1_704_164_645))
    }

    @Test func dosListing() {
        let e = FTPListParser.parseLIST("01-02-24  03:04AM       <DIR>          Program Files\n01-02-2024  03:04PM  1234 a b.txt")
        #expect(e.count == 2)
        #expect(e[0].kind == .directory && e[0].name == "Program Files")
        #expect(e[1].size == 1234 && e[1].modified == Date(timeIntervalSince1970: 1_704_207_840))
    }

    @Test func urlEncoding() throws {
        let fs = try FTPFileSystem(site: Site(path: "x", fileProtocol: .ftp, hostName: "h", port: 21), user: "u", password: "p")
        #expect(fs.url("/a b/c#d.txt") == "ftp://h:21/%2Fa%20b/c%23d.txt")
        #expect(fs.url("/", directory: true) == "ftp://h:21/%2F/")
    }
}

private let ftpdDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duckscp-test-ftpd")

private func openssl(_ args: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: ftpdDir.appendingPathComponent("ftpd.pid").path)), .serialized)
struct FTPSPinningTests {
    func site() -> Site {
        Site(path: "ftps", fileProtocol: .ftp, ftpEncryption: .explicitTLS, hostName: "127.0.0.1", port: 2121, userName: "tester")
    }

    func store() -> HostKeyStore {
        HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID()).json"), knownHostsFiles: [])
    }

    @Test func pinMatchesOpenSSL() throws {
        let pem = try String(contentsOf: ftpdDir.appendingPathComponent("cert.pem.crt"), encoding: .utf8)
        let der = try #require(Certificate.firstDER(fromPEM: pem))
        let spki = try openssl(["x509", "-in", ftpdDir.appendingPathComponent("cert.pem.crt").path, "-pubkey", "-noout"])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pub-\(UUID()).pem")
        try spki.write(to: tmp)
        let spkiDER = try openssl(["pkey", "-pubin", "-in", tmp.path, "-outform", "der"])
        #expect(Certificate.subjectPublicKeyInfo(der) == spkiDER)
    }

    @Test func rememberedCertificateIsPinned() throws {
        let keys = store()
        let first = TestPrompter()
        first.acceptCertificate = true
        first.saveCertificate = true
        _ = try FTPFileSystem.connect(site: site(), password: "secret", prompter: first, hostKeys: keys).list("/")
        #expect(first.certificateAsked == 1 && first.certificateChanged == [false])
        #expect(keys.certificate(host: "127.0.0.1", port: 2121) != nil)

        let second = TestPrompter() // rejects anything it is asked
        _ = try FTPFileSystem.connect(site: site(), password: "secret", prompter: second, hostKeys: keys).list("/")
        #expect(second.certificateAsked == 0)
    }

    @Test func changedCertificateIsReported() throws {
        let keys = store()
        // Pretend we accepted a different certificate earlier.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=other",
                         "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path])
        let other = try #require(Certificate.firstDER(fromPEM: try String(contentsOf: dir.appendingPathComponent("c.pem"), encoding: .utf8)))
        try keys.save(host: "127.0.0.1", port: 2121, key: HostKey(type: "x509", blob: other))

        let p = TestPrompter()
        #expect(throws: FileSystemError.self) { try FTPFileSystem.connect(site: site(), password: "secret", prompter: p, hostKeys: keys) }
        #expect(p.certificateChanged == [true])
    }
}
