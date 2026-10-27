import Foundation
import Testing
@testable import SCPCore

private func fixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "winscp.sample", withExtension: "ini", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct PasswordTests {
    @Test func roundTrip() throws {
        for pw in ["", "x", "pässwörd €", String(repeating: "long", count: 30)] {
            let enc = WinSCPPassword.encode(pw, key: "userhost")
            #expect(try WinSCPPassword.decode(enc, key: "userhost") == pw)
        }
    }

    @Test func wrongKeyIsRejected() {
        let enc = WinSCPPassword.encode("secret", key: "alicehost")
        #expect(throws: WinSCPPassword.DecodeError.keyMismatch) { try WinSCPPassword.decode(enc, key: "bobhost") }
    }

    @Test func garbageIsRejected() {
        #expect(throws: WinSCPPassword.DecodeError.self) { try WinSCPPassword.decode("ZZ", key: "") }
        #expect(throws: WinSCPPassword.DecodeError.self) { try WinSCPPassword.decode("A35C", key: "") }
    }
}

@Suite struct ImporterTests {
    let result: WinSCPIniImporter.Result

    init() throws {
        result = WinSCPIniImporter(keySearchDirectories: []).importData(try fixture())
    }

    func site(_ path: String) throws -> Site {
        try #require(result.sites.first { $0.path == path })
    }

    @Test func importsAllSessionsExceptDefaultsAndWorkspaces() {
        #expect(result.sites.map(\.path) == [
            "Production/web-01", "Production/db server", "Staging/ftp.example.org",
            "Clients/Acme/legacy-ftp", "localhost test", "webdav box", "s3 bucket",
        ])
        #expect(result.workspaces.map(\.name) == ["My Workspace"])
        #expect(result.workspaces.first?.sites.first?.hostName == "web01.example.com")
    }

    @Test func decodesPasswordsFromPythonGenerator() throws {
        #expect(result.passwords[try site("Production/web-01").id] == "S3cr3t!pass")
        #expect(result.passwords[try site("Staging/ftp.example.org").id] == "pässwörd €")
        #expect(result.passwords[try site("localhost test").id] == "a-very-long-password-that-exceeds-the-fifty-byte-padding-limit")
        #expect(result.passwords[try site("Production/db server").id] == nil)
    }

    @Test func mapsProtocolsAndPorts() throws {
        let web = try site("Production/web-01")
        #expect(web.fileProtocol == .sftp && !web.allowScpFallback && web.port == 22)
        #expect(web.remoteDirectory == "/var/www")
        #expect(web.localDirectory == "" && web.importWarnings.contains { $0.contains("Windows local directory") })
        #expect(web.note == "Main web node" && web.color == 4227327)

        let db = try site("Production/db server")
        #expect(db.fileProtocol == .scp && db.port == 2200)
        #expect(db.importWarnings.contains { $0.contains("id_ed25519.ppk") })

        let ftp = try site("Staging/ftp.example.org")
        #expect(ftp.fileProtocol == .ftp && ftp.ftpEncryption == .explicitTLS && ftp.port == 21 && ftp.ftpPassive)

        let legacy = try site("Clients/Acme/legacy-ftp")
        #expect(legacy.port == 2121 && !legacy.ftpPassive && legacy.folders == ["Clients", "Acme"])

        let local = try site("localhost test")
        #expect(local.fileProtocol == .sftp && local.allowScpFallback && local.port == 2222)

        #expect(try !site("webdav box").fileProtocol.isSupported)
        #expect(try site("s3 bucket").fileProtocol == .s3)
    }

    @Test func collectsHostKeys() {
        #expect(result.hostKeys.first?.key == "ssh-ed25519@22:web01.example.com")
    }

    @Test func masterPasswordSkipsPasswords() {
        let ini = "[Configuration\\Security]\r\nUseMasterPassword=1\r\n[Sessions\\a]\r\nHostName=h\r\nUserName=u\r\nPassword=\(WinSCPPassword.encode("p", key: "uh"))\r\n"
        let r = WinSCPIniImporter(keySearchDirectories: []).importData(Data(ini.utf8))
        #expect(r.passwords.isEmpty && r.messages.contains { $0.contains("master password") })
    }

    @Test func findsMappedKeyFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("id_ed25519.ppk"))
        let r = WinSCPIniImporter(keySearchDirectories: [dir]).importData(try fixture())
        let db = try #require(r.sites.first { $0.path == "Production/db server" })
        #expect(db.privateKeyPath == dir.appendingPathComponent("id_ed25519.ppk").path)
        #expect(db.importWarnings.isEmpty)
    }

    @Test func handlesBomAndCp1252() {
        var bom = Data([0xEF, 0xBB, 0xBF]); bom.append(Data("[Sessions\\x]\nHostName=h\n".utf8))
        #expect(WinSCPIniImporter().importData(bom).sites.first?.hostName == "h")
        let cp = Data("[Sessions\\x]\nHostName=h\nNote=caf".utf8) + Data([0xE9])
        #expect(WinSCPIniImporter().importData(cp).sites.first?.note == "café")
    }
}

@Suite struct SiteStoreTests {
    @Test func mergeRenamesClashesAndStoresPasswordsOutsideJson() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sites.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = InMemorySecretStore()
        let store = SiteStore(fileURL: url, secrets: secrets)
        let result = WinSCPIniImporter(keySearchDirectories: []).importData(try fixture())
        try store.merge(result)
        try store.merge(WinSCPIniImporter(keySearchDirectories: []).importData(try fixture()))
        #expect(store.sites.contains { $0.path == "Production/web-01 (2)" })

        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("S3cr3t"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let web = try #require(store.sites.first { $0.path == "Production/web-01" })
        #expect(secrets.password(for: web.id) == "S3cr3t!pass")
        try store.delete(web.id)
        #expect(secrets.password(for: web.id) == nil)
        #expect(SiteStore(fileURL: url, secrets: secrets).sites.count == store.sites.count)
    }
}
