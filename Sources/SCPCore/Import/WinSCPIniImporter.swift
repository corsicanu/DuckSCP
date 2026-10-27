import Foundation

/// Imports stored sessions from a WinSCP.ini file.
public struct WinSCPIniImporter {
    public struct Result {
        public var sites: [Site] = []
        /// Decoded passwords keyed by site id. Callers move these into the Keychain.
        public var passwords: [UUID: String] = [:]
        /// Raw `[SshHostKeys]` entries, e.g. "ssh-ed25519@22:host" -> "0x..,0x..".
        public var hostKeys: [(key: String, value: String)] = []
        /// File-level messages (master password, skipped workspaces, ...).
        public var messages: [String] = []
        /// WinSCP preferences found in the file, applied on top of the current ones.
        public var preferenceChanges: [(name: String, apply: (inout Preferences) -> Void)] = []
    }

    /// Where Windows key file names are looked up on this Mac.
    public var keySearchDirectories: [URL]

    public init(keySearchDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")]) {
        self.keySearchDirectories = keySearchDirectories
    }

    public func importFile(at url: URL) throws -> Result {
        try importData(Data(contentsOf: url))
    }

    public func importData(_ data: Data) -> Result {
        let ini = IniFile(data: data)
        var result = Result()

        let masterPassword = ini.section("Configuration\\Security")?["UseMasterPassword"] == "1"
        if masterPassword {
            result.messages.append("This WinSCP.ini is protected by a master password. Sites were imported without passwords; enter them on first login.")
        }

        var skippedWorkspaces = Set<String>()
        for section in ini.sections {
            let prefix = "Sessions\\"
            guard section.name.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let rawName = String(section.name.dropFirst(prefix.count))
            let path = rawName.split(separator: "/").map { winscpUnmunge(String($0)) }.joined(separator: "/")
            if path.isEmpty || path == "Default Settings" { continue }
            if section["IsWorkspace"] == "1" {
                skippedWorkspaces.insert(path.split(separator: "/").first.map(String.init) ?? path)
                continue
            }
            let (site, password) = makeSite(path: path, section: section, masterPassword: masterPassword)
            result.sites.append(site)
            if let password { result.passwords[site.id] = password }
        }
        if !skippedWorkspaces.isEmpty {
            result.messages.append("Skipped workspaces (not supported yet): \(skippedWorkspaces.sorted().joined(separator: ", ")).")
        }
        if let keys = ini.section("SshHostKeys") {
            result.hostKeys = keys.entries
        }
        result.preferenceChanges = preferences(ini)
        return result
    }

    /// Best-effort mapping of WinSCP's [Configuration\…] keys to our preferences.
    /// Keys are looked up in any Configuration section, so layout differences between
    /// WinSCP versions do not matter; unknown keys are ignored.
    func preferences(_ ini: IniFile) -> [(name: String, apply: (inout Preferences) -> Void)] {
        let config = ini.sections.filter { $0.name.lowercased().hasPrefix("configuration") }
        func value(_ key: String) -> String? { config.lazy.compactMap { $0[key] }.first }
        func bool(_ key: String) -> Bool? { value(key).flatMap { $0 == "1" ? true : $0 == "0" ? false : nil } }
        func int(_ key: String) -> Int? { value(key).flatMap { Int($0) } }
        var out: [(String, (inout Preferences) -> Void)] = []
        if let v = bool("ConfirmOverwriting") { out.append(("Confirm overwriting", { $0.confirmOverwrite = v })) }
        if let v = bool("ConfirmDeleting") { out.append(("Confirm deleting", { $0.confirmDelete = v })) }
        if let v = bool("ConfirmClosingSession") { out.append(("Confirm closing session", { $0.confirmDisconnect = v })) }
        if let v = bool("ShowHiddenFiles") { out.append(("Show hidden files", { $0.showHiddenFiles = v })) }
        if let v = bool("DeleteToRecycleBin") { out.append(("Delete to Trash", { $0.useTrashForLocalDelete = v })) }
        // TDoubleClickAction: 0 open, 1 copy, 2 edit
        if let v = int("DoubleClickAction"), (0...2).contains(v) {
            let action: Preferences.DoubleClickAction = [.open, .copy, .edit][v]
            out.append(("Double-click action", { $0.doubleClickAction = action }))
        }
        if let v = bool("PreserveTime") { out.append(("Preserve timestamp", { $0.preserveTimestamp = v })) }
        if let v = bool("PreserveRights") { out.append(("Preserve permissions", { $0.preservePermissions = v })) }
        // TResumeSupport: 0 on, 1 smart (threshold), 2 off
        if let v = int("ResumeSupport") { out.append(("Transfer resume", { $0.resumeEnabled = v != 2 })) }
        if let v = int("ResumeThreshold"), v >= 0 { out.append(("Resume threshold", { $0.resumeThresholdKB = max(1, v / 1024) })) }
        if let v = int("CPSLimit"), v >= 0 { out.append(("Speed limit", { $0.speedLimitKBps = v / 1024 })) }
        return out
    }

    private func makeSite(path: String, section: IniFile.Section, masterPassword: Bool) -> (Site, String?) {
        func str(_ k: String) -> String { section[k].map(winscpUnmunge) ?? "" }
        func int(_ k: String) -> Int? { section[k].flatMap { Int($0) } }

        var warnings: [String] = []
        // WinSCP TFSProtocol: 0 SCP, 1 SFTP (SCP fallback), 2 SFTP only, 5 FTP, 6 WebDAV, 7 S3.
        let proto: FileProtocol
        var scpFallback = false
        switch int("FSProtocol") ?? 1 {
        case 0: proto = .scp
        case 1: proto = .sftp; scpFallback = true
        case 2: proto = .sftp
        case 5: proto = .ftp
        case 6: proto = .webdav
        case 7: proto = .s3
        case let other:
            proto = .sftp
            warnings.append("Unknown protocol code \(other); defaulted to SFTP.")
        }
        if !proto.isSupported {
            warnings.append("\(proto.title) is not supported yet; this site cannot connect.")
        }
        // WinSCP TFtps: 0 none, 1 implicit, 2 explicit SSL (legacy), 3 explicit TLS.
        let enc: FtpEncryption
        switch int("Ftps") ?? 0 {
        case 1: enc = .implicitTLS
        case 2, 3: enc = .explicitTLS
        default: enc = .none
        }

        var keyPath = str("PublicKeyFile")
        if !keyPath.isEmpty, keyPath.contains("\\") || !FileManager.default.fileExists(atPath: keyPath) {
            let base = keyPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? keyPath
            if let found = keySearchDirectories.map({ $0.appendingPathComponent(base) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                keyPath = found.path
            } else {
                warnings.append("Private key \"\(keyPath)\" was not found on this Mac. Select it in Advanced settings.")
            }
        }

        var localDir = str("LocalDirectory")
        if localDir.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil || localDir.hasPrefix("\\\\") {
            warnings.append("Windows local directory \"\(localDir)\" was dropped.")
            localDir = ""
        }

        let host = str("HostName")
        let user = str("UserName")
        var password: String?
        if let enc = section["Password"], !enc.isEmpty, !masterPassword {
            do {
                password = try WinSCPPassword.decode(enc, key: user + host)
            } catch {
                warnings.append("Stored password could not be decoded.")
            }
        }

        var site = Site(path: path, fileProtocol: proto, allowScpFallback: scpFallback,
                        ftpEncryption: enc, ftpPassive: section["FtpPasvMode"] != "0",
                        hostName: host, port: int("PortNumber"), userName: user,
                        privateKeyPath: keyPath, remoteDirectory: str("RemoteDirectory"),
                        localDirectory: localDir, note: str("Note"), color: int("Color"),
                        hasStoredPassword: password != nil, importWarnings: warnings)
        site.sshCompression = section["Compression"] == "1"
        // TimeDifference is a TDateTime fraction of a day.
        if let d = section["TimeDifference"].flatMap(Double.init), d.isFinite {
            site.timeOffsetHours = (d * 24 * 100).rounded() / 100
        }
        return (site, password)
    }
}
