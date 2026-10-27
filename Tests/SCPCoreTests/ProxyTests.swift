// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SCPCore

private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
private let proxyLog = tmp.appendingPathComponent("duckscp-test-ftpd/proxy.log")
private let proxyUp = FileManager.default.fileExists(atPath: tmp.appendingPathComponent("duckscp-test-ftpd/proxy.pid").path)
private let sshUp = FileManager.default.fileExists(atPath: tmp.appendingPathComponent("duckscp-test-sshd/sshd.pid").path)

private func proxy(_ kind: ProxySettings.Kind, auth: Bool) -> ProxySettings {
    var p = ProxySettings()
    p.kind = kind
    p.host = "127.0.0.1"
    p.port = 3121
    if auth { p.user = "puser" }
    return p
}

private func settings(_ password: String?) -> ConnectionSettings {
    var s = ConnectionSettings()
    s.proxyPassword = password
    return s
}

private func logged(_ prefix: String) -> Bool {
    ((try? String(contentsOf: proxyLog, encoding: .utf8)) ?? "").contains(prefix)
}

@Suite(.enabled(if: proxyUp && sshUp, "start scripts/test_sshd.sh and scripts/test_ftpd.sh"), .serialized)
struct ProxyTests {
    let keys = HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("px-\(UUID()).json"), knownHostsFiles: [])

    func sshSite(_ p: ProxySettings) -> Site {
        var s = Site(path: "p", fileProtocol: .sftp, allowScpFallback: false, hostName: "127.0.0.1", port: 2222, userName: NSUserName(),
                     privateKeyPath: tmp.appendingPathComponent("duckscp-test-sshd/id_ed25519").path)
        s.proxy = p
        return s
    }

    func ftpSite(_ p: ProxySettings) -> Site {
        var s = Site(path: "f", fileProtocol: .ftp, hostName: "127.0.0.1", port: 2121, userName: "tester")
        s.proxy = p
        return s
    }

    @Test func sshThroughEachProxyType() throws {
        try? Data().write(to: proxyLog)
        for (kind, auth, tag) in [(ProxySettings.Kind.socks5, true, "socks5 127.0.0.1:2222"), (.socks5, false, "socks5"),
                                  (.socks4, false, "socks4 127.0.0.1:2222"), (.http, true, "http 127.0.0.1:2222")] {
            let fs = try Connector.connect(site: sshSite(proxy(kind, auth: auth)), password: nil, prompter: TestPrompter(),
                                           hostKeys: keys, settings: settings(auth ? "ppass" : nil))
            #expect(try fs.homeDirectory() == NSHomeDirectory())
            fs.close()
            #expect(logged(tag), "\(kind) not used")
        }
    }

    @Test func wrongProxyPasswordFails() {
        for kind in [ProxySettings.Kind.socks5, .http] {
            #expect(throws: FileSystemError.self) {
                try Connector.connect(site: sshSite(proxy(kind, auth: true)), password: nil, prompter: TestPrompter(),
                                      hostKeys: keys, settings: settings("wrong"))
            }
        }
    }

    @Test func ftpThroughSocks5AndHTTP() throws {
        try? Data().write(to: proxyLog)
        for kind in [ProxySettings.Kind.socks5, .http] {
            let fs = try Connector.connect(site: ftpSite(proxy(kind, auth: true)), password: "secret", prompter: TestPrompter(),
                                           hostKeys: keys, settings: settings("ppass"))
            try exerciseFileSystem(fs, parent: "/")
            #expect(logged(kind == .http ? "http 127.0.0.1:2121" : "socks5 127.0.0.1:2121"))
        }
    }

    @Test func curlURLs() {
        #expect(proxy(.socks5, auth: false).curlURL == "socks5h://127.0.0.1:3121")
        #expect(proxy(.socks4, auth: false).curlURL == "socks4a://127.0.0.1:3121")
        #expect(ProxySettings().curlURL == nil)
    }
}

@Suite struct ProxyImportTests {
    @Test func importsWinSCPProxySettings() throws {
        let enc = WinSCPPassword.encode("ppass", key: "pu" + "proxy.local")
        let ini = "[Sessions\\s]\nHostName=h\nProxyMethod=2\nProxyHost=proxy.local\nProxyPort=1081\nProxyUsername=pu\nProxyPasswordEnc=\(enc)\n[Sessions\\t]\nHostName=h\nProxyMethod=4\n"
        let r = WinSCPIniImporter(keySearchDirectories: []).importData(Data(ini.utf8))
        let s = try #require(r.sites.first)
        #expect(s.proxy.kind == .socks5 && s.proxy.host == "proxy.local" && s.proxy.port == 1081 && s.proxy.user == "pu")
        #expect(r.proxyPasswords[s.proxy.secretID] == "ppass")
        #expect(r.sites[1].proxy.kind == .none && r.sites[1].importWarnings.contains { $0.contains("Telnet") })

        let secrets = InMemorySecretStore()
        let store = SiteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID())/s.json"), secrets: secrets)
        try store.merge(r)
        let stored = try #require(store.sites.first { $0.proxy.kind == .socks5 })
        #expect(secrets.password(for: stored.proxy.secretID) == "ppass")
    }
}
