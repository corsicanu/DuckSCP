import Foundation

public enum RecursiveOps {
    /// Deletes a remote file or directory tree. Symlinks are removed, never followed.
    public static func delete(_ path: String, entry: RemoteEntry, fs: RemoteFileSystem, depth: Int = 0) throws {
        guard depth < TransferEngine.maxDepth else { throw FileSystemError(.other, "Directory tree too deep: \(path)") }
        if entry.kind == .directory {
            for child in try fs.list(path) where RemotePath.isSafeName(child.name) {
                try delete(RemotePath.join(path, child.name), entry: child, fs: fs, depth: depth + 1)
            }
            try fs.removeDirectory(path)
        } else {
            try fs.removeFile(path)
        }
    }
}

/// Copies files between the local disk and a `RemoteFileSystem`, recursively,
/// with WinSCP's overwrite prompts, `.filepart` temp files and resume.
public final class TransferEngine {
    public static let maxDepth = 64
    /// WinSCP's default threshold for transferring via a temporary ".filepart" file.
    public static let partialThreshold: UInt64 = 100 * 1024

    public struct Options: Equatable {
        public var preserveTimestamp = true
        /// Upload only: copy local permission bits to the server.
        public var preservePermissions = false
        public var resume = true
        public init() {}
    }

    public struct Conflict {
        public let name: String
        public let sourceSize: UInt64
        public let sourceDate: Date?
        public let targetSize: UInt64
        public let targetDate: Date?
    }

    public enum Decision { case overwrite, overwriteAll, skip, skipAll, newerOnly, cancel }

    public struct Progress {
        public var fileName = ""
        public var fileDone: UInt64 = 0
        public var fileTotal: UInt64 = 0
        public var totalDone: UInt64 = 0
        public var total: UInt64 = 0
        public var filesDone = 0
        public init() {}
    }

    private let fs: RemoteFileSystem
    private let options: Options
    private let ask: (Conflict) -> Decision
    private let report: (Progress) -> Bool
    private var progress = Progress()
    private var sticky: Decision?

    /// - Parameters:
    ///   - ask: called (on the worker thread) when the target exists.
    ///   - report: progress callback; return false to cancel.
    public init(fs: RemoteFileSystem, options: Options = Options(),
                ask: @escaping (Conflict) -> Decision, report: @escaping (Progress) -> Bool) {
        self.fs = fs
        self.options = options
        self.ask = ask
        self.report = report
    }

    // MARK: Download

    public func download(from remoteDir: String, entries: [RemoteEntry], to localDir: URL, deleteSource: Bool = false) throws {
        progress.total = try entries.reduce(0) { $0 + (try remoteSize(RemotePath.join(remoteDir, $1.name), $1, depth: 0)) }
        for e in entries {
            let src = RemotePath.join(remoteDir, e.name)
            try downloadItem(src, e, into: localDir, depth: 0)
            if deleteSource { try RecursiveOps.delete(src, entry: e, fs: fs) }
        }
    }

    private func remoteSize(_ path: String, _ e: RemoteEntry, depth: Int) throws -> UInt64 {
        guard e.isDirectoryLike else { return e.size }
        guard depth < Self.maxDepth else { return 0 }
        return try fs.list(path).filter { RemotePath.isSafeName($0.name) }
            .reduce(0) { $0 + (try remoteSize(RemotePath.join(path, $1.name), $1, depth: depth + 1)) }
    }

    private func downloadItem(_ src: String, _ e: RemoteEntry, into localDir: URL, depth: Int) throws {
        // Server-supplied names must not escape the target folder ("../", "/").
        guard RemotePath.isSafeName(e.name) else { throw FileSystemError(.other, "Refusing unsafe file name from server: \(e.name)") }
        guard depth < Self.maxDepth else { throw FileSystemError(.other, "Directory tree too deep: \(src)") }
        let dst = localDir.appendingPathComponent(e.name)
        if e.isDirectoryLike {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: dst.path, isDirectory: &isDir) {
                try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
            } else if !isDir.boolValue {
                throw FileSystemError(.exists, "\(dst.path) exists and is not a folder.")
            }
            for child in try fs.list(src) {
                try downloadItem(RemotePath.join(src, child.name), child, into: dst, depth: depth + 1)
            }
            if options.preserveTimestamp, let m = e.modified {
                try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: dst.path)
            }
            return
        }

        let existing = try? FileManager.default.attributesOfItem(atPath: dst.path)
        let part = URL(fileURLWithPath: dst.path + ".filepart")
        let partSize = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
        var offset: UInt64 = 0
        if let existing {
            let decision = resolve(Conflict(name: e.name, sourceSize: e.size, sourceDate: e.modified,
                                            targetSize: (existing[.size] as? UInt64) ?? 0,
                                            targetDate: existing[.modificationDate] as? Date))
            if decision == .cancel { throw FileSystemError.cancelled }
            if decision == .skip { return skipFile(e.size) }
        }
        if options.resume, fs.supportsResume, partSize > 0, partSize < e.size {
            offset = partSize
        }
        let usePart = e.size >= Self.partialThreshold || offset > 0
        let target = usePart ? part : dst
        try startFile(e.name, total: e.size, done: offset)
        try fs.download(src, to: target, offset: offset) { [self] n in tick(n) }
        if usePart {
            _ = try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: part, to: dst)
        }
        if options.preserveTimestamp, let m = e.modified {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: dst.path)
        }
        finishFile(e.size)
    }

    // MARK: Upload

    public func upload(_ locals: [URL], to remoteDir: String, deleteSource: Bool = false) throws {
        progress.total = locals.reduce(0) { $0 + localSize($1, depth: 0) }
        for url in locals {
            try uploadItem(url, into: remoteDir, depth: 0)
            if deleteSource { try FileManager.default.removeItem(at: url) }
        }
    }

    private func localSize(_ url: URL, depth: Int) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true && values?.isDirectory != true {
            return UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        guard values?.isDirectory == true else { return UInt64(values?.fileSize ?? 0) }
        guard depth < Self.maxDepth else { return 0 }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.reduce(0) { $0 + localSize($1, depth: depth + 1) }
    }

    private func uploadItem(_ url: URL, into remoteDir: String, depth: Int) throws {
        guard depth < Self.maxDepth else { throw FileSystemError(.other, "Directory tree too deep: \(url.path)") }
        let name = url.lastPathComponent
        let dst = RemotePath.join(remoteDir, name)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        let modified = attrs[.modificationDate] as? Date
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value

        if attrs[.type] as? FileAttributeType == .typeDirectory {
            let existing = try? fs.stat(dst)
            if existing == nil { try fs.makeDirectory(dst) }
            else if existing?.isDirectoryLike == false { throw FileSystemError(.exists, "\(dst) exists and is not a directory.") }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try uploadItem(child, into: dst, depth: depth + 1)
            }
            if options.preservePermissions, let mode { try? fs.setPermissions(dst, mode & 0o7777) }
            return
        }

        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let part = dst + ".filepart"
        var offset: UInt64 = 0
        if let existing = try? fs.stat(dst) {
            let decision = resolve(Conflict(name: name, sourceSize: size, sourceDate: modified,
                                            targetSize: existing.size, targetDate: existing.modified))
            if decision == .cancel { throw FileSystemError.cancelled }
            if decision == .skip { return skipFile(size) }
        }
        let usePart = fs.supportsResume && size >= Self.partialThreshold
        if usePart, options.resume, let p = try? fs.stat(part), p.size > 0, p.size < size {
            offset = p.size
        }
        try startFile(name, total: size, done: offset)
        try fs.upload(url, to: usePart ? part : dst, offset: offset) { [self] n in tick(n) }
        if usePart {
            if (try? fs.stat(dst)) != nil { try fs.removeFile(dst) }
            try fs.rename(part, to: dst)
        }
        if options.preserveTimestamp, let modified { try? fs.setModificationDate(dst, modified) }
        if options.preservePermissions, let mode { try? fs.setPermissions(dst, mode & 0o7777) }
        finishFile(size)
    }

    // MARK: Helpers

    /// Applies "to all" answers and "newer only"; returns .overwrite or .skip.
    private func resolve(_ c: Conflict) -> Decision {
        var d = sticky ?? ask(c)
        switch d {
        case .overwriteAll: sticky = .overwriteAll; d = .overwrite
        case .skipAll: sticky = .skipAll; d = .skip
        case .newerOnly:
            sticky = .newerOnly
            d = (c.sourceDate ?? .distantPast) > (c.targetDate ?? .distantPast) ? .overwrite : .skip
        case .overwrite, .skip, .cancel: break
        }
        return d
    }

    private var lastFileDone: UInt64 = 0
    private var cancelled = false

    private func startFile(_ name: String, total: UInt64, done: UInt64) throws {
        if cancelled { throw FileSystemError.cancelled }
        progress.fileName = name
        progress.fileTotal = total
        progress.fileDone = done
        progress.totalDone += done
        lastFileDone = done
        if !report(progress) { throw FileSystemError.cancelled }
    }

    /// Called from the file system's progress callback with the running byte count.
    private func tick(_ n: UInt64) -> Bool {
        progress.totalDone += n &- lastFileDone
        progress.fileDone = n
        lastFileDone = n
        let ok = report(progress)
        if !ok { cancelled = true }
        return ok
    }

    private func finishFile(_ size: UInt64) {
        progress.totalDone += size &- lastFileDone
        progress.fileDone = size
        progress.filesDone += 1
        lastFileDone = 0
        _ = report(progress)
    }

    private func skipFile(_ size: UInt64) {
        progress.totalDone += size
        progress.filesDone += 1
        _ = report(progress)
    }
}
