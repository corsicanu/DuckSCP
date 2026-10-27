// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// WinSCP's Synchronize: compares a local and a remote directory tree and
/// produces a list of actions that the user can review before running them.
public struct Synchronizer {
    public enum Direction: String, CaseIterable { case both, remote, local } // remote = update remote, local = update local

    public enum Criteria: String, CaseIterable { case time, size, timeAndSize }

    public struct Options {
        public var direction: Direction = .both
        /// Mirror mode: delete files that exist only on the target side (not used with `.both`).
        public var deleteObsolete = false
        public var criteria: Criteria = .time
        public var exclude = FileMask("")
        /// Timestamps closer than this count as equal (FTP and FAT only keep 1–2 s precision).
        public var timeTolerance: TimeInterval = 2
        public init() {}
    }

    public struct Action: Equatable {
        public enum Kind: String { case upload, download, deleteLocal, deleteRemote, conflict }
        public var kind: Kind
        /// Path relative to both roots, "/" separated.
        public var relativePath: String
        public var isDirectory: Bool
        public var size: UInt64
        public var reason: String
        /// Remote entry (for downloads and remote deletes).
        public var remote: RemoteEntry?
    }

    public let fs: RemoteFileSystem
    public let options: Options

    public init(fs: RemoteFileSystem, options: Options) {
        self.fs = fs
        self.options = options
    }

    private var uploads: Bool { options.direction != .local }
    private var downloads: Bool { options.direction != .remote }

    // MARK: Planning

    public func plan(localRoot: URL, remoteRoot: String) throws -> [Action] {
        var out: [Action] = []
        try compare(localRoot, remoteRoot, "", depth: 0, into: &out)
        return out
    }

    private struct LocalItem { var isDirectory: Bool; var size: UInt64; var modified: Date? }

    private func localListing(_ dir: URL) throws -> [String: LocalItem] {
        var out: [String: LocalItem] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) {
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { continue } // links are not synchronized (loop safety)
            out[url.lastPathComponent] = LocalItem(isDirectory: v.isDirectory == true, size: UInt64(v.fileSize ?? 0),
                                                   modified: v.contentModificationDate)
        }
        return out
    }

    private func compare(_ local: URL, _ remote: String, _ rel: String, depth: Int, into out: inout [Action]) throws {
        guard depth < TransferEngine.maxDepth else { return }
        let locals = try localListing(local)
        var remotes: [String: RemoteEntry] = [:]
        for e in try fs.list(remote) where RemotePath.isSafeName(e.name) && e.kind != .symlink { remotes[e.name] = e }

        for name in Set(locals.keys).union(remotes.keys).sorted() {
            let l = locals[name], r = remotes[name]
            let isDir = l?.isDirectory ?? r?.isDirectoryLike ?? false
            if options.exclude.matches(name, isDirectory: isDir) { continue }
            let path = rel.isEmpty ? name : rel + "/" + name
            switch (l, r) {
            case let (l?, r?) where l.isDirectory && r.isDirectoryLike:
                try compare(local.appendingPathComponent(name), RemotePath.join(remote, name), path, depth: depth + 1, into: &out)
            case let (l?, r?) where l.isDirectory != r.isDirectoryLike:
                out.append(Action(kind: .conflict, relativePath: path, isDirectory: false, size: 0,
                                  reason: "File on one side, folder on the other", remote: r))
            case let (l?, r?):
                if let a = compareFiles(path, l, r) { out.append(a) }
            case let (l?, nil):
                if uploads {
                    out.append(Action(kind: .upload, relativePath: path, isDirectory: l.isDirectory, size: l.size, reason: "New local \(l.isDirectory ? "folder" : "file")"))
                } else if options.deleteObsolete {
                    out.append(Action(kind: .deleteLocal, relativePath: path, isDirectory: l.isDirectory, size: l.size, reason: "Not on remote"))
                }
            case let (nil, r?):
                if downloads {
                    out.append(Action(kind: .download, relativePath: path, isDirectory: r.isDirectoryLike, size: r.size, reason: "New remote \(r.isDirectoryLike ? "folder" : "file")", remote: r))
                } else if options.deleteObsolete {
                    out.append(Action(kind: .deleteRemote, relativePath: path, isDirectory: r.isDirectoryLike, size: r.size, reason: "Not on local", remote: r))
                }
            case (nil, nil):
                break
            }
        }
    }

    private func compareFiles(_ path: String, _ l: LocalItem, _ r: RemoteEntry) -> Action? {
        let lt = l.modified ?? .distantPast, rt = r.modified ?? .distantPast
        let timeDiffers = abs(lt.timeIntervalSince(rt)) > options.timeTolerance
        let sizeDiffers = l.size != r.size
        let differs: Bool
        switch options.criteria {
        case .time: differs = timeDiffers
        case .size: differs = sizeDiffers
        case .timeAndSize: differs = timeDiffers || sizeDiffers
        }
        guard differs else { return nil }
        let localNewer = lt > rt || (!timeDiffers && sizeDiffers && options.direction == .remote)
        let reason = timeDiffers ? (localNewer ? "Local is newer" : "Remote is newer") : "Sizes differ"
        switch options.direction {
        case .remote: return Action(kind: .upload, relativePath: path, isDirectory: false, size: l.size, reason: reason)
        case .local: return Action(kind: .download, relativePath: path, isDirectory: false, size: r.size, reason: reason, remote: r)
        case .both:
            guard timeDiffers else {
                return Action(kind: .conflict, relativePath: path, isDirectory: false, size: 0,
                              reason: "Same time, different size: cannot tell which is newer", remote: r)
            }
            return localNewer
                ? Action(kind: .upload, relativePath: path, isDirectory: false, size: l.size, reason: reason)
                : Action(kind: .download, relativePath: path, isDirectory: false, size: r.size, reason: reason, remote: r)
        }
    }

    // MARK: Running

    /// Runs the actions (conflicts are skipped). Files are always overwritten;
    /// `deleteLocal` uses `trash` when given (Preferences → Trash), otherwise deletes.
    public func run(_ actions: [Action], localRoot: URL, remoteRoot: String, transfer: TransferEngine.Options,
                    trash: ((URL) throws -> Void)? = nil, report: @escaping (TransferEngine.Progress) -> Bool) throws {
        let engine = TransferEngine(fs: fs, options: transfer, ask: { _ in .overwrite }, report: report)
        for a in actions {
            let localURL = localRoot.appendingPathComponent(a.relativePath)
            let remotePath = RemotePath.join(remoteRoot, a.relativePath)
            switch a.kind {
            case .upload:
                try engine.upload([localURL], to: RemotePath.parent(remotePath))
            case .download:
                guard let r = a.remote else { continue }
                try engine.download(from: RemotePath.parent(remotePath), entries: [r], to: localURL.deletingLastPathComponent())
            case .deleteRemote:
                guard let r = a.remote else { continue }
                try RecursiveOps.delete(remotePath, entry: r, fs: fs)
            case .deleteLocal:
                if let trash { try trash(localURL) } else { try FileManager.default.removeItem(at: localURL) }
            case .conflict:
                continue
            }
        }
    }
}
