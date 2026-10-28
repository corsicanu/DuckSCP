// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
@testable import SCPCore

@Suite struct SemVerTests {
    @Test func ordering() {
        let v = { SemVer($0)! }
        #expect(v("1.0.1") > v("1.0.0"))
        #expect(v("v1.1.0") > v("1.0.9"))
        #expect(v("1.0.1-beta.1") < v("1.0.1"))
        #expect(v("1.0.1-beta.2") > v("1.0.1-beta.1"))
        #expect(v("1.0.1-beta.10") > v("1.0.1-beta.9"))
        #expect(v("1.0.1-rc.1") > v("1.0.1-beta.5"))
        #expect(v("1.0.2-beta.1") > v("1.0.1"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(SemVer("latest") == nil)
    }

    @Test func historyIsMostRecentFirstWithoutDuplicates() {
        var list: [String] = []
        for p in ["/a", "/b", "/a", " ", "/c"] { Preferences.remember(p, in: &list) }
        #expect(list == ["/c", "/a", "/b"])
        for i in 0..<30 { Preferences.remember("/p\(i)", in: &list) }
        #expect(list.count == Preferences.historyLimit && list.first == "/p29")
    }
}

/// A fake GitHub: releases JSON plus a zipped, ad-hoc signed test app, served by python's http.server.
final class FakeGitHub {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fakegh-\(UUID())")
    let port = Int.random(in: 41000...49000)
    private var server: Process?
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FileSystemError(.other, "\(tool) failed") }
    }

    /// Builds DuckSCP.app (bundle id/version as given), signs it, zips it, writes checksums.
    func publish(version: String, bundleID: String = "test.duckscp", tamper: Bool = false, prerelease: Bool = false) throws {
        let assets = root.appendingPathComponent("dl")
        let app = root.appendingPathComponent("build-\(version)/DuckSCP.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "DuckSCP", "CFBundlePackageType": "APPL", "CFBundleName": "DuckSCP"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        let exe = app.appendingPathComponent("Contents/MacOS/DuckSCP")
        try "#!/bin/sh\necho \(version)\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let zipName = "DuckSCP-\(version)-macOS-arm64.zip"
        let zip = assets.appendingPathComponent(zipName)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        var digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        if tamper { digest = String(repeating: "0", count: 64) }
        try "\(digest)  \(zipName)\n".write(to: assets.appendingPathComponent("SHA256SUMS.txt"), atomically: true, encoding: .utf8)
        let release: [String: Any] = [
            "tag_name": "v\(version)", "name": "DuckSCP \(version)", "body": "Notes for \(version)", "prerelease": prerelease,
            "draft": false, "html_url": "https://example.invalid/releases/v\(version)",
            "assets": [["name": zipName, "browser_download_url": "\(base)/dl/\(zipName)"],
                       ["name": "SHA256SUMS.txt", "browser_download_url": "\(base)/dl/SHA256SUMS.txt"]],
        ]
        let api = root.appendingPathComponent("repos/corsicanu/DuckSCP")
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [release]).write(to: api.appendingPathComponent("releases"))
    }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", root.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        server = p
        Thread.sleep(forTimeInterval: 1.0)
    }

    deinit {
        server?.terminate()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) struct UpdaterTests {
    @Test func findsDownloadsVerifiesAndInstalls() async throws {
        let gh = FakeGitHub()
        try gh.publish(version: "1.0.2")
        try gh.start()
        let releases = try await Updater.fetchReleases(repo: "corsicanu/DuckSCP", apiBase: gh.base)
        let r = try #require(Updater.newest(in: releases, newerThan: SemVer("1.0.1")!))
        #expect(r.tagName == "v1.0.2" && !r.prerelease)
        #expect(Updater.newest(in: releases, newerThan: SemVer("1.0.2")!) == nil)

        let app = try await Updater.download(r, arch: "arm64", bundleID: "test.duckscp")
        #expect(app.lastPathComponent == "DuckSCP.app")

        // Swap an "installed" copy, as the app does after quitting (pid 1 never exits for us, so use a finished one).
        let installDir = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID())")
        let installed = installDir.appendingPathComponent("DuckSCP.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old".write(to: installed.appendingPathComponent("Contents/old.txt"), atomically: true, encoding: .utf8)
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run(); done.waitUntilExit()
        try Updater.scheduleReplace(target: installed, with: app, afterExitOf: done.processIdentifier, relaunch: false)
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: plist.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect((NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) == "1.0.2")
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/old.txt").path))
        #expect(!FileManager.default.fileExists(atPath: installDir.appendingPathComponent(".DuckSCP.app.old").path))
    }

    @Test func prereleaseIsOfferedAndMarked() async throws {
        let gh = FakeGitHub()
        try gh.publish(version: "1.1.0-beta.1", prerelease: true)
        try gh.start()
        let releases = try await Updater.fetchReleases(repo: "corsicanu/DuckSCP", apiBase: gh.base)
        let r = try #require(Updater.newest(in: releases, newerThan: SemVer("1.0.1")!))
        #expect(r.prerelease && r.version == SemVer("1.1.0-beta.1"))
    }

    @Test func tamperedPackageIsRefused() async throws {
        let gh = FakeGitHub()
        try gh.publish(version: "1.0.2", tamper: true)
        try gh.start()
        let r = try #require(try await Updater.fetchReleases(repo: "corsicanu/DuckSCP", apiBase: gh.base).first)
        await #expect(throws: Updater.UpdateError.self) { try await Updater.download(r, arch: "arm64", bundleID: "test.duckscp") }
    }

    @Test func otherAppIsRefused() async throws {
        let gh = FakeGitHub()
        try gh.publish(version: "1.0.2", bundleID: "evil.app")
        try gh.start()
        let r = try #require(try await Updater.fetchReleases(repo: "corsicanu/DuckSCP", apiBase: gh.base).first)
        await #expect(throws: Updater.UpdateError.self) { try await Updater.download(r, arch: "arm64", bundleID: "test.duckscp") }
    }

    @Test func readOnlyOrDiskImageLocationIsRefused() {
        #expect(throws: Updater.UpdateError.self) {
            try Updater.scheduleReplace(target: URL(fileURLWithPath: "/Volumes/DuckSCP 1.0.1/DuckSCP.app"),
                                        with: URL(fileURLWithPath: "/tmp/x.app"), afterExitOf: 1, relaunch: false)
        }
    }
}
