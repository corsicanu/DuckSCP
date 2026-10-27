// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// WinSCP's Find Files: recursive remote search by file mask.
public struct FileFinder {
    public struct Criteria {
        public var mask = FileMask("*")
        public var minSize: UInt64 = 0
        public var modifiedAfter: Date?
        public var includeDirectories = false
        public init() {}
    }

    public let fs: RemoteFileSystem
    public let criteria: Criteria

    public init(fs: RemoteFileSystem, criteria: Criteria) {
        self.fs = fs
        self.criteria = criteria
    }

    /// Walks `root` breadth-first. `found` gets (directory, entry); return false from
    /// `shouldContinue` to stop. Unreadable folders are skipped and reported via `skipped`.
    public func search(_ root: String, shouldContinue: () -> Bool = { true },
                       skipped: (String, Error) -> Void = { _, _ in },
                       found: (String, RemoteEntry) -> Void) {
        var queue = [(root, 0)]
        while !queue.isEmpty, shouldContinue() {
            let (dir, depth) = queue.removeFirst()
            let entries: [RemoteEntry]
            do { entries = try fs.list(dir) } catch { skipped(dir, error); continue }
            for e in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            where RemotePath.isSafeName(e.name) {
                if matches(e) { found(dir, e) }
                // Real directories only: following links could loop.
                if e.kind == .directory && depth < TransferEngine.maxDepth { queue.append((RemotePath.join(dir, e.name), depth + 1)) }
                if !shouldContinue() { return }
            }
        }
    }

    private func matches(_ e: RemoteEntry) -> Bool {
        if e.isDirectoryLike && !criteria.includeDirectories { return false }
        guard criteria.mask.matches(e.name, isDirectory: false) else { return false }
        if !e.isDirectoryLike && e.size < criteria.minSize { return false }
        if let after = criteria.modifiedAfter, (e.modified ?? .distantPast) < after { return false }
        return true
    }
}
