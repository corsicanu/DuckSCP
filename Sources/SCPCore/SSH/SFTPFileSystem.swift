import CLibSSH2
import Foundation

public final class SFTPFileSystem: RemoteFileSystem {
    private let conn: SSHConnection
    private let sftp: OpaquePointer
    private static let chunk = 256 * 1024

    public init(connection: SSHConnection) throws {
        conn = connection
        guard let s = libssh2_sftp_init(connection.session) else {
            throw connection.error("Cannot initialize SFTP protocol. Is the host running an SFTP server?", code: .unsupported)
        }
        sftp = s
    }

    deinit { close() }

    public var protocolName: String { "SFTP-3" }
    public var supportsResume: Bool { true }
    private var closed = false

    public func close() {
        guard !closed else { return }
        closed = true
        libssh2_sftp_shutdown(sftp)
        conn.close()
    }

    public func keepalive() { conn.keepalive() }

    private func fail(_ what: String, _ path: String) -> FileSystemError {
        let code = libssh2_sftp_last_error(sftp)
        switch code {
        case LIBSSH2_FX_NO_SUCH_FILE, LIBSSH2_FX_NO_SUCH_PATH: return FileSystemError(.notFound, "No such file or directory: \(path)")
        case LIBSSH2_FX_PERMISSION_DENIED: return FileSystemError(.permissionDenied, "Permission denied: \(path)")
        case LIBSSH2_FX_FILE_ALREADY_EXISTS: return FileSystemError(.exists, "\(path) already exists.")
        case LIBSSH2_FX_DIR_NOT_EMPTY: return FileSystemError(.other, "Directory \(path) is not empty.")
        case LIBSSH2_FX_OK: return conn.error("\(what) \(path)")
        default: return FileSystemError(.other, "\(what) \(path) failed (SFTP error \(code)).")
        }
    }

    public func homeDirectory() throws -> String { try realPath(".") }

    public func realPath(_ path: String) throws -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = macscp_sftp_realpath(sftp, path, &buf, UInt32(buf.count))
        guard n > 0 else { throw fail("Cannot resolve", path) }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        guard let handle = macscp_sftp_opendir(sftp, path) else { throw fail("Cannot open directory", path) }
        defer { libssh2_sftp_close_handle(handle) }
        var entries: [RemoteEntry] = []
        var name = [CChar](repeating: 0, count: 4096)
        var long = [CChar](repeating: 0, count: 4096)
        while true {
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            let n = libssh2_sftp_readdir_ex(handle, &name, name.count, &long, long.count, &attrs)
            if n == 0 { break }
            if n < 0 { throw fail("Cannot read directory", path) }
            let fileName = String(decoding: name.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if fileName == "." || fileName == ".." { continue }
            var e = entry(fileName, attrs)
            // SFTP v3 only carries numeric ids; the "ls -l" long name has the user names.
            let longName = String(cString: long)
            let fields = longName.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 4 {
                e.owner = String(fields[2])
                e.group = String(fields[3])
            }
            if e.kind == .symlink { resolveLink(&e, RemotePath.join(path, fileName)) }
            entries.append(e)
        }
        return entries
    }

    private func resolveLink(_ e: inout RemoteEntry, _ full: String) {
        var target = [CChar](repeating: 0, count: 4096)
        let n = macscp_sftp_readlink(sftp, full, &target, UInt32(target.count))
        if n > 0 { e.linkTarget = String(decoding: target.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        if macscp_sftp_stat(sftp, full, &attrs) == 0 {
            e.targetIsDirectory = UInt32(attrs.permissions) & UInt32(LIBSSH2_SFTP_S_IFMT) == UInt32(LIBSSH2_SFTP_S_IFDIR)
            if !e.targetIsDirectory { e.size = attrs.filesize }
        }
    }

    private func entry(_ name: String, _ a: LIBSSH2_SFTP_ATTRIBUTES) -> RemoteEntry {
        let has = { (flag: Int32) in a.flags & UInt(flag) != 0 }
        let mode = UInt32(a.permissions)
        let type = mode & UInt32(LIBSSH2_SFTP_S_IFMT)
        let kind: RemoteEntry.Kind = type == UInt32(LIBSSH2_SFTP_S_IFDIR) ? .directory : type == UInt32(LIBSSH2_SFTP_S_IFLNK) ? .symlink : .file
        return RemoteEntry(name: name, kind: kind,
                           size: has(LIBSSH2_SFTP_ATTR_SIZE) ? a.filesize : 0,
                           modified: has(LIBSSH2_SFTP_ATTR_ACMODTIME) ? Date(timeIntervalSince1970: TimeInterval(a.mtime)) : nil,
                           permissions: has(LIBSSH2_SFTP_ATTR_PERMISSIONS) ? mode & 0o7777 : nil,
                           owner: has(LIBSSH2_SFTP_ATTR_UIDGID) ? String(a.uid) : "",
                           group: has(LIBSSH2_SFTP_ATTR_UIDGID) ? String(a.gid) : "")
    }

    public func stat(_ path: String) throws -> RemoteEntry {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        guard macscp_sftp_lstat(sftp, path, &attrs) == 0 else { throw fail("Cannot get attributes of", path) }
        var e = entry(RemotePath.name(path), attrs)
        if e.kind == .symlink { resolveLink(&e, path) }
        return e
    }

    public func makeDirectory(_ path: String) throws {
        guard macscp_sftp_mkdir(sftp, path, 0o755) == 0 else { throw fail("Cannot create directory", path) }
    }

    public func removeFile(_ path: String) throws {
        guard macscp_sftp_unlink(sftp, path) == 0 else { throw fail("Cannot delete", path) }
    }

    public func removeDirectory(_ path: String) throws {
        guard macscp_sftp_rmdir(sftp, path) == 0 else { throw fail("Cannot remove directory", path) }
    }

    public func rename(_ from: String, to: String) throws {
        guard macscp_sftp_rename(sftp, from, to) == 0 else { throw fail("Cannot rename", from) }
    }

    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        attrs.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attrs.permissions = UInt(mode & 0o7777)
        guard macscp_sftp_setstat(sftp, path, &attrs) == 0 else { throw fail("Cannot change permissions of", path) }
    }

    public func setModificationDate(_ path: String, _ date: Date) throws {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        attrs.flags = UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)
        attrs.mtime = UInt(max(0, date.timeIntervalSince1970))
        attrs.atime = attrs.mtime
        guard macscp_sftp_setstat(sftp, path, &attrs) == 0 else { throw fail("Cannot set timestamp of", path) }
    }

    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        guard let handle = macscp_sftp_open(sftp, path, UInt(LIBSSH2_FXF_READ), 0) else { throw fail("Cannot open", path) }
        defer { libssh2_sftp_close_handle(handle) }
        let out = try LocalFile.openForWriting(local, append: offset > 0)
        defer { try? out.close() }
        libssh2_sftp_seek64(handle, offset)
        var total = offset
        var buf = [CChar](repeating: 0, count: Self.chunk)
        while true {
            let n = libssh2_sftp_read(handle, &buf, buf.count)
            if n == 0 { break }
            if n < 0 { throw fail("Error reading", path) }
            try buf.withUnsafeBytes { try out.write(contentsOf: Data($0.prefix(n))) }
            total += UInt64(n)
            if !progress(total) { throw FileSystemError.cancelled }
        }
    }

    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: local) } catch {
            throw FileSystemError(.notFound, "Cannot open \(local.path): \(error.localizedDescription)")
        }
        defer { try? input.close() }
        let flags = LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | (offset > 0 ? 0 : LIBSSH2_FXF_TRUNC)
        guard let handle = macscp_sftp_open(sftp, path, UInt(flags), 0o644) else { throw fail("Cannot create", path) }
        defer { libssh2_sftp_close_handle(handle) }
        try input.seek(toOffset: offset)
        libssh2_sftp_seek64(handle, offset)
        var total = offset
        while true {
            let chunk = try input.read(upToCount: Self.chunk) ?? Data()
            if chunk.isEmpty { break }
            try chunk.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = libssh2_sftp_write(handle, raw.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self), raw.count - sent)
                    if n < 0 { throw fail("Error writing", path) }
                    sent += n
                }
            }
            total += UInt64(chunk.count)
            if !progress(total) { throw FileSystemError.cancelled }
        }
    }
}
