import Foundation

/// WebDAV (RFC 4918) over HTTP or HTTPS ("Encryption: TLS" in the Login dialog).
public final class WebDAVFileSystem: RemoteFileSystem {
    private let http: HTTPClient

    public static func connect(site: Site, password: String?, prompter: ConnectionPrompter,
                               settings: ConnectionSettings = .init(), hostKeys: HostKeyStore? = nil) throws -> WebDAVFileSystem {
        var current = password
        for attempt in 0..<4 {
            if current == nil, !site.userName.isEmpty {
                guard let p = prompter.askPassword(attempt == 0 ? "Password:" : "Access denied. Password:") else { throw FileSystemError.cancelled }
                current = p
            }
            prompter.status("Connecting to \(site.hostName)...")
            let fs = try WebDAVFileSystem(site: site, password: current ?? "", settings: settings)
            do {
                try fs.http.establishTrust(prompter: prompter, hostKeys: hostKeys) { _ = try fs.stat(fs.root) }
                return fs
            } catch let e as FileSystemError where e.code == .authentication {
                current = nil
                if attempt == 3 || site.userName.isEmpty { throw e }
            }
        }
        throw FileSystemError(.authentication, "Access denied.")
    }

    init(site: Site, password: String, settings: ConnectionSettings) throws {
        http = try HTTPClient(site: site)
        http.settings = settings
        if !site.userName.isEmpty { http.auth = .basicOrDigest(user: site.userName, password: password) }
    }

    public var protocolName: String { http.isTLS ? "WebDAVS" : "WebDAV" }
    /// Plain PUT cannot append, so uploads restart; downloads resume with Range.
    public var supportsResume: Bool { false }
    public func close() {}

    private var root: String { http.site.remoteDirectory.isEmpty ? "/" : http.site.remoteDirectory }

    private func url(_ path: String, directory: Bool = false) -> String {
        var u = http.baseURL + "/" + HTTPClient.encodePath(path)
        if directory && !u.hasSuffix("/") { u += "/" }
        return u
    }

    public func homeDirectory() throws -> String { root }

    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
    """.utf8)

    private func propfind(_ path: String, depth: Int, directory: Bool) throws -> [WebDAVParser.Item] {
        let r = try http.perform(.init(method: "PROPFIND", url: url(path, directory: directory),
                                       headers: ["Depth: \(depth)", "Content-Type: application/xml"], body: Self.propfindBody),
                                 what: "Listing", path: path)
        try HTTPClient.check(r, "Listing", path, ok: [207])
        return WebDAVParser.parse(r.body)
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        let own = "/" + HTTPClient.encodePath(path)
        return try propfind(path, depth: 1, directory: true)
            .filter { WebDAVParser.normalize($0.href) != WebDAVParser.normalize(own) }
            .compactMap { $0.entry }
    }

    public func stat(_ path: String) throws -> RemoteEntry {
        guard let item = try propfind(path, depth: 0, directory: false).first, item.ok else {
            throw FileSystemError(.notFound, "No such file or directory: \(path)")
        }
        // Built from the requested path: the root "/" has no name of its own.
        return RemoteEntry(name: path == "/" ? "/" : RemotePath.name(path), kind: item.isCollection ? .directory : .file,
                           size: item.size, modified: item.modified)
    }

    public func makeDirectory(_ path: String) throws {
        let r = try http.perform(.init(method: "MKCOL", url: url(path, directory: true)), what: "Creating directory", path: path)
        try HTTPClient.check(r, "Creating directory", path)
    }

    public func removeFile(_ path: String) throws {
        let r = try http.perform(.init(method: "DELETE", url: url(path)), what: "Deleting", path: path)
        try HTTPClient.check(r, "Deleting", path)
    }

    public func removeDirectory(_ path: String) throws {
        let r = try http.perform(.init(method: "DELETE", url: url(path, directory: true)), what: "Removing directory", path: path)
        try HTTPClient.check(r, "Removing directory", path)
    }

    public func rename(_ from: String, to: String) throws {
        let isDir = (try? stat(from))?.isDirectoryLike ?? false
        let r = try http.perform(.init(method: "MOVE", url: url(from, directory: isDir),
                                       headers: ["Destination: \(url(to, directory: isDir))", "Overwrite: F"]),
                                 what: "Renaming", path: from)
        try HTTPClient.check(r, "Renaming", from)
    }

    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        throw FileSystemError(.unsupported, "WebDAV has no file permissions.")
    }

    /// Most servers refuse to change getlastmodified; ignored like WinSCP.
    public func setModificationDate(_ path: String, _ date: Date) throws {}

    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let out = try LocalFile.openForWriting(local, append: offset > 0)
        defer { try? out.close() }
        try withoutActuallyEscaping(progress) { progress in
            let r = try http.perform(.init(url: url(path), downloadTo: out, rangeFrom: offset, progress: progress, progressStart: offset),
                                     what: "Downloading", path: path)
            if offset > 0 && r.status == 200 { throw FileSystemError(.other, "Server ignored the resume request for \(path).") }
            try HTTPClient.check(r, "Downloading", path)
        }
    }

    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: local) } catch {
            throw FileSystemError(.notFound, "Cannot open \(local.path): \(error.localizedDescription)")
        }
        defer { try? input.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try withoutActuallyEscaping(progress) { progress in
            let r = try http.perform(.init(method: "PUT", url: url(path), uploadFile: input, uploadSize: size, progress: progress),
                                     what: "Uploading", path: path)
            try HTTPClient.check(r, "Uploading", path)
        }
    }
}

/// Parses PROPFIND multistatus responses.
enum WebDAVParser {
    struct Item {
        var href = ""
        var isCollection = false
        var size: UInt64 = 0
        var modified: Date?
        var ok = true

        var entry: RemoteEntry? {
            let name = (WebDAVParser.normalize(href).split(separator: "/").last.map(String.init) ?? "").removingPercentEncoding ?? ""
            guard ok, RemotePath.isSafeName(name) else { return nil }
            return RemoteEntry(name: name, kind: isCollection ? .directory : .file, size: size, modified: modified)
        }
    }

    /// "/a/b/" and "http://h/a/b" both become "/a/b".
    static func normalize(_ href: String) -> String {
        var path = href
        if let u = URL(string: href), u.host != nil { path = u.path.isEmpty ? "/" : u.path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.removingPercentEncoding ?? path
    }

    static func parse(_ data: Data) -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""
        // A <propstat> lists its properties before its <status>, so collect, then apply if 200.
        private var pendingCollection = false
        private var pendingSize: UInt64?
        private var pendingModified: Date?
        private var propstatOK = true

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "response": current = Item()
            case "propstat":
                propstatOK = true
                pendingCollection = false
                pendingSize = nil
                pendingModified = nil
            case "collection": pendingCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href": if current?.href.isEmpty == true { current?.href = value }
            case "status": propstatOK = value.contains(" 200")
            case "getcontentlength": pendingSize = UInt64(value)
            case "getlastmodified": pendingModified = Self.dateFormatter.date(from: value)
            case "propstat":
                if propstatOK {
                    if pendingCollection { current?.isCollection = true }
                    if let s = pendingSize { current?.size = s }
                    if let m = pendingModified { current?.modified = m }
                }
            case "response":
                if let c = current { items.append(c) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
