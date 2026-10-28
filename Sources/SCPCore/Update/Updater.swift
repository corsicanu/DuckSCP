// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Security

/// Semantic version ("1.0.1", "v1.1.0-beta.2"). Pre-releases sort before their release.
public struct SemVer: Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: [String]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(separator: "+", maxSplits: 1)[0] // build metadata is ignored
        let parts = core.split(separator: "-", maxSplits: 1)
        let nums = parts[0].split(separator: ".").map { Int($0) }
        guard (1...3).contains(nums.count), nums.allSatisfy({ $0 != nil }) else { return nil }
        major = nums[0]!
        minor = nums.count > 1 ? nums[1]! : 0
        patch = nums.count > 2 ? nums[2]! : 0
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false):
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                switch (Int(x), Int(y)) {
                case let (i?, j?): return i < j
                case (_?, nil): return true
                case (nil, _?): return false
                default: return x < y
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }

    public static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

/// Checks GitHub Releases for a newer DuckSCP and installs it in place.
public enum Updater {
    public struct Asset: Decodable {
        public let name: String
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    public struct Release: Decodable {
        public let tagName: String
        public let name: String?
        public let body: String?
        public let prerelease: Bool
        public let draft: Bool
        public let htmlURL: URL
        public let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, prerelease, draft, htmlURL = "html_url", assets
        }

        public var version: SemVer? { SemVer(tagName) }
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case noPackage, checksumMissing, checksumMismatch, badPackage(String), notWritable(String), differentSigner

        public var description: String {
            switch self {
            case .noPackage: return "The release has no package for this Mac."
            case .checksumMissing: return "The release has no checksum for its package, so it cannot be verified."
            case .checksumMismatch: return "The downloaded update is damaged (checksum mismatch). Nothing was changed."
            case .badPackage(let why): return "The downloaded update is not valid: \(why). Nothing was changed."
            case .notWritable(let path): return "DuckSCP cannot replace itself at \(path). Download the update from the release page instead."
            case .differentSigner: return "The update is signed by a different certificate than this copy of DuckSCP, so it was not installed."
            }
        }
    }

    /// All releases of `repo` ("owner/name"), newest first as GitHub lists them.
    public static func fetchReleases(repo: String, apiBase: URL = URL(string: "https://api.github.com")!,
                                     session: URLSession = .shared) async throws -> [Release] {
        var req = URLRequest(url: apiBase.appendingPathComponent("repos/\(repo)/releases"))
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DuckSCP-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FileSystemError(.connection, "GitHub answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    /// Highest version newer than `current`; pre-releases count too (the caller warns about them).
    public static func newest(in releases: [Release], newerThan current: SemVer) -> Release? {
        releases.filter { !$0.draft }
            .compactMap { r in r.version.map { (r, $0) } }
            .filter { $0.1 > current }
            .max { $0.1 < $1.1 }?.0
    }

    /// The zip for this Mac ("DuckSCP-1.0.1-macOS-arm64.zip") and the checksum list.
    public static func package(in release: Release, arch: String) -> (zip: Asset, sums: Asset?)? {
        guard let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") && $0.name.contains("macOS") && $0.name.contains(arch) })
            ?? release.assets.first(where: { $0.name.hasSuffix(".zip") && $0.name.contains("macOS") }) else { return nil }
        return (zip, release.assets.first { $0.name == "SHA256SUMS.txt" })
    }

    /// Downloads and checks an update, returning the new app unpacked in a temp folder.
    /// Checks: SHA-256 against the release's SHA256SUMS.txt, a valid code signature,
    /// the same bundle id as the running app and the version the release claims.
    public static func download(_ release: Release, arch: String, bundleID: String,
                                session: URLSession = .shared) async throws -> URL {
        guard let pkg = package(in: release, arch: arch) else { throw UpdateError.noPackage }
        guard let sumsAsset = pkg.sums else { throw UpdateError.checksumMissing }
        let (sumsData, _) = try await session.data(from: sumsAsset.browserDownloadURL)
        guard let expected = checksum(for: pkg.zip.name, in: String(decoding: sumsData, as: UTF8.self)) else {
            throw UpdateError.checksumMissing
        }
        let (tmpZip, _) = try await session.download(from: pkg.zip.browserDownloadURL)
        let zipData = try Data(contentsOf: tmpZip)
        let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("duckscp-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(pkg.zip.name)
        try zipData.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appendingPathComponent("unpacked").path])
        guard let app = try FileManager.default.contentsOfDirectory(at: work.appendingPathComponent("unpacked"), includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.badPackage("no app inside") }
        try verify(app: app, bundleID: bundleID, version: release.version)
        return app
    }

    /// Code signature, bundle id and version of a downloaded app.
    public static func verify(app: URL, bundleID: String, version: SemVer?) throws {
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) } catch {
            throw UpdateError.badPackage("its code signature does not verify")
        }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.badPackage("missing Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.badPackage("it is a different app") }
        if let version, let v = (info["CFBundleShortVersionString"] as? String).flatMap(SemVer.init), v != version {
            throw UpdateError.badPackage("it is version \(v), not \(version)")
        }
    }

    /// The new app must satisfy the running app's designated requirement, i.e. be signed
    /// by the same certificate. Skipped when the running app is signed ad hoc (its
    /// requirement is its own code hash, which no other build can match).
    public static func verifySameSigner(_ newApp: URL, as current: URL) throws {
        var currentCode: SecStaticCode?, newCode: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess, let currentCode,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess, let requirement else { return }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        if (text as String?)?.contains("cdhash") ?? true { return } // ad hoc: nothing stable to compare
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCode) == errSecSuccess, let newCode,
              SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw UpdateError.differentSigner
        }
    }

    static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts.last.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }) == name {
                return String(parts[0])
            }
        }
        return nil
    }

    /// Replaces `target` (the installed app) with `newApp` once process `pid` has quit,
    /// then opens it. Runs as a detached shell script; the old copy is restored if the
    /// copy fails. Returns the script path (for tests).
    @discardableResult
    public static func scheduleReplace(target: URL, with newApp: URL, afterExitOf pid: Int32, relaunch: Bool = true) throws -> URL {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), !target.path.hasPrefix("/Volumes/") else {
            throw UpdateError.notWritable(target.path)
        }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let backup = parent.appendingPathComponent(".\(target.lastPathComponent).old")
        let script = """
        #!/bin/sh
        # DuckSCP self-update: wait for the app to quit, swap the bundle, relaunch.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(backup.path))
        mv \(q(target.path)) \(q(backup.path)) || exit 1
        if /usr/bin/ditto \(q(newApp.path)) \(q(target.path)); then
          rm -rf \(q(backup.path))
        else
          rm -rf \(q(target.path)); mv \(q(backup.path)) \(q(target.path))
        fi
        \(relaunch ? "/usr/bin/open \(q(target.path))" : "")
        rm -rf \(q(newApp.deletingLastPathComponent().deletingLastPathComponent().path))
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duckscp-update-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [url.path]
        try p.run()
        return url
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FileSystemError(.other, "\(tool) failed: \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
