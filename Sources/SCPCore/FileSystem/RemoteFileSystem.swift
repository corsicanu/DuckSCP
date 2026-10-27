import Foundation

/// One directory entry, used for both local and remote panels.
public struct RemoteEntry: Equatable {
    public enum Kind: Equatable { case file, directory, symlink }

    public var name: String
    public var kind: Kind
    /// For symlinks: whether the target is a directory (so the panel can enter it).
    public var targetIsDirectory: Bool
    public var size: UInt64
    public var modified: Date?
    /// POSIX mode bits (permissions only, 0o7777), if known.
    public var permissions: UInt32?
    public var owner: String
    public var group: String
    public var linkTarget: String?

    public init(name: String, kind: Kind, targetIsDirectory: Bool = false, size: UInt64 = 0, modified: Date? = nil,
                permissions: UInt32? = nil, owner: String = "", group: String = "", linkTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.targetIsDirectory = targetIsDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.linkTarget = linkTarget
    }

    /// True for directories and links to directories.
    public var isDirectoryLike: Bool { kind == .directory || (kind == .symlink && targetIsDirectory) }

    /// "rwxr-xr-x" as shown in WinSCP's Rights column.
    public var rightsString: String {
        guard let p = permissions else { return "" }
        return RemoteEntry.rights(p)
    }

    public static func rights(_ p: UInt32) -> String {
        let chars: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
                                            (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        var s = String(chars.map { p & $0.0 != 0 ? $0.1 : "-" })
        func special(_ bit: UInt32, _ index: Int, _ set: Character, _ unset: Character) {
            guard p & bit != 0 else { return }
            let i = s.index(s.startIndex, offsetBy: index)
            s.replaceSubrange(i...i, with: String(s[i] == "x" ? set : unset))
        }
        special(0o4000, 2, "s", "S")
        special(0o2000, 5, "s", "S")
        special(0o1000, 8, "t", "T")
        return s
    }
}

/// Errors with user-facing text, shown verbatim in WinSCP-style error dialogs.
public struct FileSystemError: Error, CustomStringConvertible, Equatable {
    public enum Code: Equatable { case notFound, permissionDenied, exists, cancelled, connection, authentication, hostKey, unsupported, other }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var description: String { message }

    public static let cancelled = FileSystemError(.cancelled, "Operation was cancelled.")
}

/// A connected remote file system. Implementations are NOT thread-safe;
/// `RemoteSession` serialises all calls on one queue.
public protocol RemoteFileSystem: AnyObject {
    /// Shown in the status bar, e.g. "SFTP-3", "SCP", "FTP".
    var protocolName: String { get }
    func homeDirectory() throws -> String
    func list(_ path: String) throws -> [RemoteEntry]
    func stat(_ path: String) throws -> RemoteEntry
    func makeDirectory(_ path: String) throws
    func removeFile(_ path: String) throws
    /// Removes an empty directory.
    func removeDirectory(_ path: String) throws
    func rename(_ from: String, to: String) throws
    func setPermissions(_ path: String, _ mode: UInt32) throws
    func setModificationDate(_ path: String, _ date: Date) throws
    /// Streams `path` into `local`. Appends when `offset` > 0. `progress` gets the
    /// running byte total and returns false to cancel.
    func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws
    func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws
    /// Whether `offset` > 0 is honoured (resume support).
    var supportsResume: Bool { get }
    /// Keeps idle connections open. Called periodically on the session queue.
    func keepalive()
    func close()
}

public extension RemoteFileSystem {
    func keepalive() {}
}

/// POSIX path helpers for remote paths (always "/" separated).
public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let i = p.lastIndex(of: "/") else { return "." }
        return i == p.startIndex ? "/" : String(p[..<i])
    }

    public static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Rejects names that would escape the target directory or are invalid on POSIX.
    /// Used for every name received from a server before writing locally.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
