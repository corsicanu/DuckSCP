import Foundation

/// Network settings applied to every new connection (Preferences → Network).
public struct ConnectionSettings {
    public var timeout: TimeInterval = 15
    public var keepalive: Int = 30
    public var ipVersion: Preferences.IPVersion = .auto
    public var log: SessionLog?
    /// Password of the site's proxy, read from the Keychain by the caller.
    public var proxyPassword: String?

    public init() {}

    public init(_ p: Preferences, log: SessionLog? = nil) {
        timeout = TimeInterval(max(1, p.connectTimeoutSeconds))
        keepalive = max(0, p.keepaliveSeconds)
        ipVersion = p.ipVersion
        self.log = log
    }
}

/// Appends timestamped lines to a log file (Preferences → Logging). Never given secrets.
public final class SessionLog {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "session.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        handle = try LocalFile.openForWriting(url, append: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func write(_ text: String) {
        let line = "\(formatter.string(from: Date())) \(text)\n"
        queue.async { [handle] in try? handle.write(contentsOf: Data(line.utf8)) }
    }
}

/// Wraps a file system and logs every operation and failure.
public final class LoggingFileSystem: RemoteFileSystem {
    let inner: RemoteFileSystem
    private let log: SessionLog
    private let tag: String

    public init(_ inner: RemoteFileSystem, log: SessionLog, tag: String) {
        self.inner = inner
        self.log = log
        self.tag = tag
    }

    private func run<T>(_ what: String, _ body: () throws -> T) throws -> T {
        log.write("[\(tag)] \(what)")
        do { return try body() } catch {
            log.write("[\(tag)] ! \(what): \(error)")
            throw error
        }
    }

    public var protocolName: String { inner.protocolName }
    public var supportsResume: Bool { inner.supportsResume }
    public func keepalive() { inner.keepalive() }
    public func close() { log.write("[\(tag)] Disconnected"); inner.close() }
    public func homeDirectory() throws -> String { try run("Home directory") { try inner.homeDirectory() } }
    public func list(_ path: String) throws -> [RemoteEntry] {
        try run("List \(path)") { try inner.list(path) }
    }
    public func stat(_ path: String) throws -> RemoteEntry { try inner.stat(path) } // too chatty to log
    public func makeDirectory(_ path: String) throws { try run("Create directory \(path)") { try inner.makeDirectory(path) } }
    public func removeFile(_ path: String) throws { try run("Delete \(path)") { try inner.removeFile(path) } }
    public func removeDirectory(_ path: String) throws { try run("Remove directory \(path)") { try inner.removeDirectory(path) } }
    public func rename(_ from: String, to: String) throws { try run("Rename \(from) → \(to)") { try inner.rename(from, to: to) } }
    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        try run("Chmod \(String(mode, radix: 8)) \(path)") { try inner.setPermissions(path, mode) }
    }
    public func setModificationDate(_ path: String, _ date: Date) throws { try inner.setModificationDate(path, date) }
    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try run("Download \(path) → \(local.path)\(offset > 0 ? " (resume at \(offset))" : "")") {
            try inner.download(path, to: local, offset: offset, progress: progress)
        }
    }
    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try run("Upload \(local.path) → \(path)\(offset > 0 ? " (resume at \(offset))" : "")") {
            try inner.upload(local, to: path, offset: offset, progress: progress)
        }
    }
}

/// Shifts remote timestamps by the site's time zone offset (WinSCP "Timezone offset"),
/// for servers whose listings are in a different zone.
public final class TimeShiftFileSystem: RemoteFileSystem {
    let inner: RemoteFileSystem
    private let offset: TimeInterval

    public init(_ inner: RemoteFileSystem, hours: Double) {
        self.inner = inner
        offset = hours * 3600
    }

    private func shift(_ e: RemoteEntry) -> RemoteEntry {
        var e = e
        e.modified = e.modified?.addingTimeInterval(offset)
        return e
    }

    public var protocolName: String { inner.protocolName }
    public var supportsResume: Bool { inner.supportsResume }
    public func keepalive() { inner.keepalive() }
    public func close() { inner.close() }
    public func homeDirectory() throws -> String { try inner.homeDirectory() }
    public func list(_ path: String) throws -> [RemoteEntry] { try inner.list(path).map(shift) }
    public func stat(_ path: String) throws -> RemoteEntry { shift(try inner.stat(path)) }
    public func makeDirectory(_ path: String) throws { try inner.makeDirectory(path) }
    public func removeFile(_ path: String) throws { try inner.removeFile(path) }
    public func removeDirectory(_ path: String) throws { try inner.removeDirectory(path) }
    public func rename(_ from: String, to: String) throws { try inner.rename(from, to: to) }
    public func setPermissions(_ path: String, _ mode: UInt32) throws { try inner.setPermissions(path, mode) }
    public func setModificationDate(_ path: String, _ date: Date) throws {
        try inner.setModificationDate(path, date.addingTimeInterval(-offset))
    }
    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try inner.download(path, to: local, offset: offset, progress: progress)
    }
    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try inner.upload(local, to: path, offset: offset, progress: progress)
    }
}
