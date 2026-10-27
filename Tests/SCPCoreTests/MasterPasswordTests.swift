// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SCPCore

@Suite struct MasterPasswordTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "winscp.master.sample", withExtension: "ini", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func roundTrip() throws {
        let enc = WinSCPMasterPassword.encrypt("pässword", masterPassword: "m")
        #expect(try WinSCPMasterPassword.decrypt(enc, masterPassword: "m") == "pässword")
        #expect(throws: WinSCPMasterPassword.Error.wrongPassword) { try WinSCPMasterPassword.decrypt(enc, masterPassword: "x") }
        // Longer than one AES block exercises the counter.
        let long = String(repeating: "0123456789", count: 7)
        #expect(try WinSCPMasterPassword.decrypt(WinSCPMasterPassword.encrypt(long, masterPassword: "m"), masterPassword: "m") == long)
    }

    @Test func verifierFromPythonGenerator() throws {
        let data = try fixture()
        #expect(WinSCPIniImporter.usesMasterPassword(data))
        #expect(WinSCPIniImporter.checkMasterPassword("master123", in: data) == true)
        #expect(WinSCPIniImporter.checkMasterPassword("wrong", in: data) == false)
    }

    @Test func importsWithMasterPassword() throws {
        let r = WinSCPIniImporter(keySearchDirectories: []).importData(try fixture(), masterPassword: "master123")
        let prod = try #require(r.sites.first { $0.path == "Secure/prod" })
        #expect(r.passwords[prod.id] == "Sup3r-secret ✓")
        let ws = try #require(r.workspaces.first)
        #expect(ws.name == "Secure/My Workspace" && ws.sites.count == 2)
        #expect(r.passwords[ws.sites[0].id] == "ws-pass" && ws.sites[0].remoteDirectory == "/var/log")
        #expect(ws.sites[1].fileProtocol == .scp)
    }

    @Test func importWithoutMasterPasswordKeepsSitesOnly() throws {
        let r = WinSCPIniImporter(keySearchDirectories: []).importData(try fixture())
        #expect(r.passwords.isEmpty && r.sites.count == 1)
        #expect(r.messages.contains { $0.contains("master password") })
    }

    @Test func workspacesPersistWithPasswords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID())/sites.json")
        let secrets = InMemorySecretStore()
        let store = SiteStore(fileURL: url, secrets: secrets)
        let r = WinSCPIniImporter(keySearchDirectories: []).importData(try fixture(), masterPassword: "master123")
        try store.merge(r)
        try store.merge(r)
        #expect(store.workspaces.map(\.name) == ["Secure/My Workspace", "Secure/My Workspace (2)"])
        let reloaded = SiteStore(fileURL: url, secrets: secrets)
        #expect(reloaded.workspaces.count == 2)
        #expect(secrets.password(for: reloaded.workspaces[0].sites[0].id) == "ws-pass")
        try store.deleteWorkspace(store.workspaces[0].id)
        #expect(store.workspaces.count == 1)
    }
}
