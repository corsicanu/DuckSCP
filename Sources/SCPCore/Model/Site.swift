import Foundation

/// File protocols offered in the Login dialog, in WinSCP's order.
public enum FileProtocol: String, Codable, CaseIterable {
    case sftp, scp, ftp, webdav, s3

    public var title: String {
        switch self {
        case .sftp: return "SFTP"
        case .scp: return "SCP"
        case .ftp: return "FTP"
        case .webdav: return "WebDAV"
        case .s3: return "Amazon S3"
        }
    }

    /// Protocols this app can actually connect with.
    public var isSupported: Bool { self == .sftp || self == .scp || self == .ftp }
}

/// FTP encryption modes, matching WinSCP's "Encryption" drop-down.
public enum FtpEncryption: String, Codable, CaseIterable {
    case none, implicitTLS, explicitTLS

    public var title: String {
        switch self {
        case .none: return "No encryption"
        case .implicitTLS: return "TLS/SSL Implicit encryption"
        case .explicitTLS: return "TLS/SSL Explicit encryption"
        }
    }
}

/// A stored site ("session" in WinSCP terms). Passwords never live here;
/// they are kept in the Keychain and looked up by `id`.
public struct Site: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Full WinSCP-style name, folders separated by "/", e.g. "Production/web-01".
    public var path: String
    public var fileProtocol: FileProtocol
    public var allowScpFallback: Bool
    public var ftpEncryption: FtpEncryption
    public var ftpPassive: Bool
    public var hostName: String
    public var port: Int
    public var userName: String
    public var privateKeyPath: String
    public var remoteDirectory: String
    public var localDirectory: String
    public var note: String
    public var color: Int?
    public var hasStoredPassword: Bool
    /// Problems found during import that the user should look at.
    public var importWarnings: [String]

    public init(id: UUID = UUID(), path: String, fileProtocol: FileProtocol = .sftp,
                allowScpFallback: Bool = true, ftpEncryption: FtpEncryption = .none,
                ftpPassive: Bool = true, hostName: String = "", port: Int? = nil,
                userName: String = "", privateKeyPath: String = "", remoteDirectory: String = "",
                localDirectory: String = "", note: String = "", color: Int? = nil,
                hasStoredPassword: Bool = false, importWarnings: [String] = []) {
        self.id = id
        self.path = path
        self.fileProtocol = fileProtocol
        self.allowScpFallback = allowScpFallback
        self.ftpEncryption = ftpEncryption
        self.ftpPassive = ftpPassive
        self.hostName = hostName
        self.userName = userName
        self.privateKeyPath = privateKeyPath
        self.remoteDirectory = remoteDirectory
        self.localDirectory = localDirectory
        self.note = note
        self.color = color
        self.hasStoredPassword = hasStoredPassword
        self.importWarnings = importWarnings
        self.port = port ?? Site.defaultPort(fileProtocol, ftpEncryption)
    }

    /// Tolerant decoding: fields added in later versions fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let proto = try c.decodeIfPresent(FileProtocol.self, forKey: .fileProtocol) ?? .sftp
        let enc = try c.decodeIfPresent(FtpEncryption.self, forKey: .ftpEncryption) ?? .none
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  path: try c.decode(String.self, forKey: .path),
                  fileProtocol: proto,
                  allowScpFallback: try c.decodeIfPresent(Bool.self, forKey: .allowScpFallback) ?? true,
                  ftpEncryption: enc,
                  ftpPassive: try c.decodeIfPresent(Bool.self, forKey: .ftpPassive) ?? true,
                  hostName: try c.decodeIfPresent(String.self, forKey: .hostName) ?? "",
                  port: try c.decodeIfPresent(Int.self, forKey: .port),
                  userName: try c.decodeIfPresent(String.self, forKey: .userName) ?? "",
                  privateKeyPath: try c.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? "",
                  remoteDirectory: try c.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? "",
                  localDirectory: try c.decodeIfPresent(String.self, forKey: .localDirectory) ?? "",
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  color: try c.decodeIfPresent(Int.self, forKey: .color),
                  hasStoredPassword: try c.decodeIfPresent(Bool.self, forKey: .hasStoredPassword) ?? false,
                  importWarnings: try c.decodeIfPresent([String].self, forKey: .importWarnings) ?? [])
    }

    public static func defaultPort(_ p: FileProtocol, _ enc: FtpEncryption) -> Int {
        switch p {
        case .sftp, .scp: return 22
        case .ftp: return enc == .implicitTLS ? 990 : 21
        case .webdav, .s3: return 443
        }
    }

    /// Last path component, shown in the site tree.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// Folder components above the site.
    public var folders: [String] { path.split(separator: "/").dropLast().map(String.init) }

    /// "user@host" label used in tabs and window titles, like WinSCP.
    public var displayTarget: String {
        userName.isEmpty ? hostName : "\(userName)@\(hostName)"
    }
}
