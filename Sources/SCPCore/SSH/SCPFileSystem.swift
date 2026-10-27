import CLibSSH2
import Foundation

/// SCP mode: files move over scp channels, everything else runs as shell
/// commands (ls, mkdir, rm, mv, chmod, touch), the way WinSCP's SCP mode works.
/// Requires a POSIX shell on the server.
public final class SCPFileSystem: RemoteFileSystem {
    private let conn: SSHConnection
    /// ls flags for exact timestamps: GNU, then BSD, then none.
    private var timeFlags = ["--full-time", "-T", ""]

    public init(connection: SSHConnection) { conn = connection }

    public var protocolName: String { "SCP" }
    public var supportsResume: Bool { false }
    public func close() { conn.close() }
    public func keepalive() { conn.keepalive() }

    /// Single-quotes for the POSIX shell; the only character needing care is "'".
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private func run(_ command: String, _ what: String, _ path: String) throws -> String {
        // C locale for parseable output, UTC so listed times need no server time zone.
        let (status, out, err) = try conn.exec("LC_ALL=C TZ=UTC " + command)
        guard status == 0 else {
            let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
            let code: FileSystemError.Code = msg.contains("No such file") ? .notFound : msg.contains("Permission denied") ? .permissionDenied : .other
            throw FileSystemError(code, "\(what) \(path) failed: \(msg.isEmpty ? "exit code \(status)" : msg)")
        }
        return String(decoding: out, as: UTF8.self)
    }

    public func homeDirectory() throws -> String {
        try run("pwd", "Getting home directory", "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        try listing("ls -la", path).filter { $0.name != "." && $0.name != ".." }
    }

    public func stat(_ path: String) throws -> RemoteEntry {
        guard var e = try listing("ls -ld", path).first else { throw FileSystemError(.notFound, "No such file or directory: \(path)") }
        e.name = RemotePath.name(path)
        return e
    }

    private func listing(_ ls: String, _ path: String) throws -> [RemoteEntry] {
        while timeFlags.count > 1 {
            do {
                return LsParser.parse(try run("\(ls) \(timeFlags[0]) \(Self.quote(path))", "Listing", path))
            } catch let e as FileSystemError where e.code == .other {
                timeFlags.removeFirst() // flag not supported by this ls; try the next format
            }
        }
        return LsParser.parse(try run("\(ls) \(Self.quote(path))", "Listing", path))
    }

    public func makeDirectory(_ path: String) throws { try run("mkdir \(Self.quote(path))", "Creating directory", path) }
    public func removeFile(_ path: String) throws { try run("rm -f \(Self.quote(path))", "Deleting", path) }
    public func removeDirectory(_ path: String) throws { try run("rmdir \(Self.quote(path))", "Removing directory", path) }
    public func rename(_ from: String, to: String) throws { try run("mv -f \(Self.quote(from)) \(Self.quote(to))", "Renaming", from) }

    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        try run("chmod \(String(mode & 0o7777, radix: 8)) \(Self.quote(path))", "Changing permissions of", path)
    }

    public func setModificationDate(_ path: String, _ date: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm.ss"
        try run("TZ=UTC touch -m -t \(f.string(from: date)) \(Self.quote(path))", "Setting timestamp of", path)
    }

    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        var info = libssh2_struct_stat()
        guard let channel = libssh2_scp_recv2(conn.session, path, &info) else { throw conn.error("Cannot download \(path)") }
        defer { libssh2_channel_free(channel) }
        let out = try LocalFile.openForWriting(local, append: false)
        defer { try? out.close() }
        let size = UInt64(info.st_size)
        var total: UInt64 = 0
        var buf = [CChar](repeating: 0, count: 256 * 1024)
        while total < size {
            let n = libssh2_channel_read_ex(channel, 0, &buf, min(buf.count, Int(size - total)))
            if n < 0 { throw conn.error("Error reading \(path)", code: .connection) }
            if n == 0 { break }
            try buf.withUnsafeBytes { try out.write(contentsOf: Data($0.prefix(n))) }
            total += UInt64(n)
            if !progress(total) { throw FileSystemError.cancelled }
        }
        guard total == size else { throw FileSystemError(.connection, "Transfer of \(path) was incomplete.") }
    }

    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mode = Int32(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o777)
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        guard let channel = duckscp_scp_send(conn.session, path, mode, size, mtime, mtime) else {
            throw conn.error("Cannot upload to \(path)")
        }
        defer { libssh2_channel_free(channel) }
        var total: UInt64 = 0
        while true {
            let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try chunk.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = libssh2_channel_write_ex(channel, 0, raw.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self), raw.count - sent)
                    if n < 0 { throw conn.error("Error writing \(path)", code: .connection) }
                    sent += n
                }
            }
            total += UInt64(chunk.count)
            if !progress(total) { throw FileSystemError.cancelled }
        }
        libssh2_channel_send_eof(channel)
        libssh2_channel_wait_eof(channel)
        libssh2_channel_wait_closed(channel)
    }
}

/// Parses `ls -la` output, GNU `--full-time` or the traditional short date format.
public enum LsParser {
    public static func parse(_ output: String, now: Date = Date()) -> [RemoteEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0), now: now) }
    }

    static func parseLine(_ line: String, now: Date) -> RemoteEntry? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil } // skips "total N"
        // Tokenise while remembering where each token ends, so names keep their spaces.
        var tokens: [(String, String.Index)] = []
        var i = line.startIndex
        while i < line.endIndex, tokens.count < 10 {
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            let start = i
            while i < line.endIndex, line[i] != " " { i = line.index(after: i) }
            if start < i { tokens.append((String(line[start..<i]), i)) }
        }
        guard tokens.count >= 8 else { return nil }
        let perms = tokens[0].0
        let owner = tokens[2].0, group = tokens[3].0
        guard let size = UInt64(tokens[4].0) else { return nil } // device files ("8, 1") are skipped
        var date: Date?
        var dateEnd: String.Index
        if tokens[5].0.contains("-"), tokens.count >= 9, tokens[6].0.contains(":") {
            // GNU --full-time: 2024-01-02 03:04:05.000000000 +0000
            date = fullTime(tokens[5].0, tokens[6].0, tokens[7].0)
            dateEnd = tokens[7].1
        } else if tokens.count >= 10, tokens[7].0.filter({ $0 == ":" }).count == 2, tokens[8].0.count == 4, Int(tokens[8].0) != nil {
            // BSD -T: Jul 14 02:40:00 2017
            date = bsdTime(tokens[5].0, tokens[6].0, tokens[7].0, tokens[8].0)
            dateEnd = tokens[8].1
        } else {
            date = shortTime(tokens[5].0, tokens[6].0, tokens[7].0, now: now)
            dateEnd = tokens[7].1
        }
        guard dateEnd < line.endIndex else { return nil }
        var name = String(line[line.index(after: dateEnd)...])
        var target: String?
        if first == "l", let arrow = name.range(of: " -> ") {
            target = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }
        let kind: RemoteEntry.Kind = first == "d" ? .directory : first == "l" ? .symlink : .file
        return RemoteEntry(name: name, kind: kind, targetIsDirectory: false, size: size, modified: date,
                           permissions: permissionBits(perms), owner: owner, group: group, linkTarget: target)
    }

    static func permissionBits(_ s: String) -> UInt32? {
        let c = Array(s)
        guard c.count >= 10 else { return nil }
        var mode: UInt32 = 0
        let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        for (k, bit) in bits.enumerated() where c[k + 1] != "-" && c[k + 1] != "S" && c[k + 1] != "T" { mode |= bit }
        if "sS".contains(c[3]) { mode |= 0o4000 }
        if "sS".contains(c[6]) { mode |= 0o2000 }
        if "tT".contains(c[9]) { mode |= 0o1000 }
        return mode
    }

    private static func fullTime(_ day: String, _ time: String, _ zone: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: "\(day) \(time.prefix(8)) \(zone)")
    }

    private static func bsdTime(_ mon: String, _ day: String, _ time: String, _ year: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d HH:mm:ss yyyy"
        return f.date(from: "\(mon) \(day) \(time) \(year)")
    }

    /// "Jan  2 03:04" (within the last 6 months) or "Jan  2  2023". Commands run with TZ=UTC.
    private static func shortTime(_ mon: String, _ day: String, _ timeOrYear: String, now: Date) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        if timeOrYear.contains(":") {
            f.dateFormat = "yyyy MMM d HH:mm"
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = f.timeZone
            let year = cal.component(.year, from: now)
            guard let d = f.date(from: "\(year) \(mon) \(day) \(timeOrYear)") else { return nil }
            // A date in the future means it was last year.
            return d > now.addingTimeInterval(86400) ? cal.date(byAdding: .year, value: -1, to: d) : d
        }
        f.dateFormat = "MMM d yyyy"
        return f.date(from: "\(mon) \(day) \(timeOrYear)")
    }
}
