import Foundation

/// Local disk access with the same shape as a remote file system.
/// Used by the local panel and as a stand-in server in tests.
public final class LocalFileSystem: RemoteFileSystem {
    private let fm = FileManager.default
    public init() {}

    public var protocolName: String { "Local" }
    public var supportsResume: Bool { true }

    public func homeDirectory() throws -> String { fm.homeDirectoryForCurrentUser.path }

    public func list(_ path: String) throws -> [RemoteEntry] {
        do {
            return try fm.contentsOfDirectory(atPath: path).map { try stat(RemotePath.join(path, $0)) }
        } catch let e as FileSystemError {
            throw e
        } catch {
            throw map(error, path)
        }
    }

    public func stat(_ path: String) throws -> RemoteEntry {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try fm.attributesOfItem(atPath: path) } catch { throw map(error, path) }
        let type = attrs[.type] as? FileAttributeType
        var entry = RemoteEntry(
            name: (path as NSString).lastPathComponent,
            kind: type == .typeDirectory ? .directory : type == .typeSymbolicLink ? .symlink : .file,
            size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attrs[.modificationDate] as? Date,
            permissions: (attrs[.posixPermissions] as? NSNumber)?.uint32Value,
            owner: attrs[.ownerAccountName] as? String ?? "",
            group: attrs[.groupOwnerAccountName] as? String ?? "")
        if entry.kind == .symlink {
            entry.linkTarget = try? fm.destinationOfSymbolicLink(atPath: path)
            var isDir: ObjCBool = false
            entry.targetIsDirectory = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        return entry
    }

    public func makeDirectory(_ path: String) throws {
        do { try fm.createDirectory(atPath: path, withIntermediateDirectories: false) } catch { throw map(error, path) }
    }

    public func removeFile(_ path: String) throws {
        do { try fm.removeItem(atPath: path) } catch { throw map(error, path) }
    }

    public func removeDirectory(_ path: String) throws {
        guard rmdir(path) == 0 else { throw FileSystemError(.other, "Cannot remove directory \(path): \(String(cString: strerror(errno)))") }
    }

    public func rename(_ from: String, to: String) throws {
        if fm.fileExists(atPath: to) { throw FileSystemError(.exists, "\(to) already exists.") }
        do { try fm.moveItem(atPath: from, toPath: to) } catch { throw map(error, from) }
    }

    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        do { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path) } catch { throw map(error, path) }
    }

    public func setModificationDate(_ path: String, _ date: Date) throws {
        do { try fm.setAttributes([.modificationDate: date], ofItemAtPath: path) } catch { throw map(error, path) }
    }

    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try copy(from: URL(fileURLWithPath: path), to: local, offset: offset, progress: progress)
    }

    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        try copy(from: local, to: URL(fileURLWithPath: path), offset: offset, progress: progress)
    }

    public func close() {}

    private func copy(from: URL, to: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: from) } catch { throw map(error, from.path) }
        defer { try? input.close() }
        let output = try LocalFile.openForWriting(to, append: offset > 0)
        defer { try? output.close() }
        try input.seek(toOffset: offset)
        var total = offset
        while true {
            let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            total += UInt64(chunk.count)
            if !progress(total) { throw FileSystemError.cancelled }
        }
    }

    private func map(_ error: Error, _ path: String) -> FileSystemError {
        let ns = error as NSError
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return FileSystemError(.notFound, "No such file or directory: \(path)")
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return FileSystemError(.permissionDenied, "Permission denied: \(path)")
        case NSFileWriteFileExistsError: return FileSystemError(.exists, "\(path) already exists.")
        default: return FileSystemError(.other, ns.localizedDescription)
        }
    }
}

public enum LocalFile {
    /// Opens (creating if needed) a local file for writing; truncates unless appending.
    /// New files get mode 0644 and symlinks at the destination are refused.
    public static func openForWriting(_ url: URL, append: Bool) throws -> FileHandle {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (append ? O_APPEND : O_TRUNC)
        let fd = open(url.path, flags, 0o644)
        guard fd >= 0 else {
            throw FileSystemError(errno == EACCES ? .permissionDenied : .other,
                                  "Cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
