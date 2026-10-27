import Foundation

/// Persists sites as JSON (owner-only permissions) and passwords via a `SecretStore`.
public final class SiteStore {
    public private(set) var sites: [Site] = []
    public let fileURL: URL
    public let secrets: SecretStore

    public init(fileURL: URL, secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        load()
    }

    public static func defaultURL(appName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("sites.json")
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { sites = []; return }
        sites = (try? JSONDecoder().decode([Site].self, from: data)) ?? []
    }

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Also tighten a folder that already existed; the atomic write briefly creates the file with umask permissions.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(sites).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func site(_ id: UUID) -> Site? { sites.first { $0.id == id } }

    /// Inserts or replaces a site. `password` nil leaves the stored one untouched;
    /// an empty string removes it.
    public func upsert(_ site: Site, password: String? = nil) throws {
        var site = site
        if let password {
            try secrets.setPassword(password.isEmpty ? nil : password, for: site.id)
            site.hasStoredPassword = !password.isEmpty
        }
        if let i = sites.firstIndex(where: { $0.id == site.id }) {
            sites[i] = site
        } else {
            sites.append(site)
        }
        try save()
    }

    public func delete(_ id: UUID) throws {
        try secrets.setPassword(nil, for: id)
        sites.removeAll { $0.id == id }
        try save()
    }

    /// Deletes every site under a folder path (e.g. "Production").
    public func deleteFolder(_ folder: String) throws {
        let prefix = folder + "/"
        for s in sites where s.path.hasPrefix(prefix) { try secrets.setPassword(nil, for: s.id) }
        sites.removeAll { $0.path.hasPrefix(prefix) }
        try save()
    }

    /// Returns a path that does not collide with an existing site, WinSCP style: "name (2)".
    public func uniquePath(_ path: String, excluding id: UUID? = nil) -> String {
        let taken = Set(sites.filter { $0.id != id }.map { $0.path.lowercased() })
        if !taken.contains(path.lowercased()) { return path }
        var n = 2
        while taken.contains("\(path) (\(n))".lowercased()) { n += 1 }
        return "\(path) (\(n))"
    }

    /// Adds imported sites, renaming on clash, and stores their passwords.
    @discardableResult
    public func merge(_ result: WinSCPIniImporter.Result) throws -> Int {
        for var site in result.sites {
            site.path = uniquePath(site.path)
            if let pw = result.passwords[site.id] { try secrets.setPassword(pw, for: site.id) }
            sites.append(site)
        }
        try save()
        return result.sites.count
    }
}
