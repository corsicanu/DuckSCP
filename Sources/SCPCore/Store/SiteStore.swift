import Foundation

/// Persists sites as JSON (owner-only permissions) and passwords via a `SecretStore`.
public final class SiteStore {
    public private(set) var sites: [Site] = []
    public private(set) var workspaces: [Workspace] = []
    private var workspacesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("workspaces.json") }
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
        sites = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Site].self, from: $0) } ?? []
        workspaces = (try? Data(contentsOf: workspacesURL)).flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
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
        try enc.encode(workspaces).write(to: workspacesURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspacesURL.path)
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

    /// Saves (or replaces, by name) a workspace. `passwords` are keyed by the sites' ids.
    public func saveWorkspace(_ workspace: Workspace, passwords: [UUID: String] = [:]) throws {
        if let old = workspaces.first(where: { $0.name == workspace.name }) {
            for s in old.sites { try secrets.setPassword(nil, for: s.id) }
            workspaces.removeAll { $0.name == workspace.name }
        }
        var ws = workspace
        for i in ws.sites.indices {
            let pw = passwords[ws.sites[i].id]
            ws.sites[i].hasStoredPassword = pw != nil
            if let pw { try secrets.setPassword(pw, for: ws.sites[i].id) }
        }
        workspaces.append(ws)
        try save()
    }

    public func deleteWorkspace(_ id: UUID) throws {
        for s in workspaces.first(where: { $0.id == id })?.sites ?? [] { try secrets.setPassword(nil, for: s.id) }
        workspaces.removeAll { $0.id == id }
        try save()
    }

    /// Adds imported sites and workspaces, renaming on clash, and stores their passwords.
    /// Everything gets fresh ids, so importing the same file twice yields independent copies.
    @discardableResult
    public func merge(_ result: WinSCPIniImporter.Result) throws -> Int {
        func fresh(_ site: Site) throws -> Site {
            var copy = site
            copy.id = UUID()
            if let pw = result.passwords[site.id] { try secrets.setPassword(pw, for: copy.id) }
            return copy
        }
        for site in result.sites {
            var copy = try fresh(site)
            copy.path = uniquePath(site.path)
            sites.append(copy)
        }
        for ws in result.workspaces {
            var copy = Workspace(name: ws.name, sites: try ws.sites.map(fresh))
            var n = 2
            while workspaces.contains(where: { $0.name == copy.name }) { copy.name = "\(ws.name) (\(n))"; n += 1 }
            workspaces.append(copy)
        }
        try save()
        return result.sites.count
    }
}
