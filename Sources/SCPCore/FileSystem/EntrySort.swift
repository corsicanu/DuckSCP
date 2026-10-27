import Foundation

/// Panel ordering: folders (and links to folders) always come first, in either
/// direction and for every column, like WinSCP; ties fall back to natural name order.
public enum EntrySort {
    public enum Key { case name, size, changed, rights, owner, type }

    public static func sort(_ entries: inout [RemoteEntry], by key: Key, ascending: Bool,
                            typeName: (RemoteEntry) -> String = { _ in "" }) {
        // Type names can be expensive (UTType lookups): resolve once per extension.
        var typeCache: [String: String] = [:]
        if key == .type {
            for e in entries where !e.isDirectoryLike {
                let ext = (e.name as NSString).pathExtension
                if typeCache[ext] == nil { typeCache[ext] = typeName(e) }
            }
        }
        func type(_ e: RemoteEntry) -> String { e.isDirectoryLike ? "" : typeCache[(e.name as NSString).pathExtension] ?? "" }

        entries.sort { a, b in
            if a.isDirectoryLike != b.isDirectoryLike { return a.isDirectoryLike }
            let ordered: ComparisonResult
            switch key {
            case .size: ordered = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .changed: ordered = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case .rights: ordered = a.rightsString.compare(b.rightsString)
            case .owner: ordered = a.owner.compare(b.owner)
            case .type: ordered = type(a).compare(type(b))
            case .name: ordered = .orderedSame
            }
            let result = ordered == .orderedSame ? a.name.localizedStandardCompare(b.name) : ordered
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
