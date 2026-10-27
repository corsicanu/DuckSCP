// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Amazon S3 and S3-compatible storage (MinIO, Wasabi, R2...), path-style addressing.
/// "/" lists buckets; "/bucket/a/b" maps to key "a/b"; folders are "/"-delimited prefixes.
/// User name = access key ID, password = secret access key; requests are signed with
/// AWS Signature V4 by libcurl.
public final class S3FileSystem: RemoteFileSystem {
    private let http: HTTPClient
    private let region: String

    public static func connect(site: Site, password: String?, prompter: ConnectionPrompter,
                               settings: ConnectionSettings = .init(), hostKeys: HostKeyStore? = nil) throws -> S3FileSystem {
        var secret = password
        if secret == nil {
            guard let p = prompter.askPassword("Secret access key:") else { throw FileSystemError.cancelled }
            secret = p
        }
        prompter.status("Connecting to \(site.hostName)...")
        let fs = try S3FileSystem(site: site, secret: secret ?? "", settings: settings)
        try fs.http.establishTrust(prompter: prompter, hostKeys: hostKeys) {
            _ = try fs.list(fs.site.remoteDirectory.isEmpty ? "/" : fs.site.remoteDirectory)
        }
        return fs
    }

    init(site: Site, secret: String, settings: ConnectionSettings) throws {
        http = try HTTPClient(site: site)
        http.settings = settings
        region = site.s3Region.isEmpty ? "us-east-1" : site.s3Region
        http.auth = .sigV4(provider: "aws:amz:\(region):s3", accessKey: site.userName, secret: secret)
    }

    private var site: Site { http.site }
    public var protocolName: String { "S3" }
    public var supportsResume: Bool { false } // S3 objects cannot be appended to
    public func close() {}
    public func homeDirectory() throws -> String { site.remoteDirectory.isEmpty ? "/" : site.remoteDirectory }

    // MARK: Paths

    /// ("bucket", "key/inside") for "/bucket/key/inside".
    static func split(_ path: String) -> (bucket: String, key: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return (parts.first ?? "", parts.dropFirst().joined(separator: "/"))
    }

    /// RFC 3986 unreserved characters only, as SigV4 requires.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private func objectURL(_ bucket: String, _ key: String) -> String {
        http.baseURL + "/" + Self.encode(bucket) + (key.isEmpty ? "" : "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/"))
    }

    private func request(_ method: String, _ url: String, headers: [String] = [], body: Data? = nil,
                         what: String, path: String) throws -> HTTPClient.Response {
        try http.perform(.init(method: method, url: url, headers: ["x-amz-content-sha256: UNSIGNED-PAYLOAD"] + headers,
                               body: body, noBody: method == "HEAD"), what: what, path: path)
    }

    private func check(_ r: HTTPClient.Response, _ what: String, _ path: String, ok: Set<Int> = []) throws {
        if (200..<300).contains(r.status) || ok.contains(r.status) { return }
        let err = S3XML.parse(r.body)
        let code = err.values["Code"]?.first ?? ""
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch":
            throw FileSystemError(.authentication, "Access denied: \(err.values["Message"]?.first ?? code).")
        case "NoSuchBucket", "NoSuchKey": throw FileSystemError(.notFound, "No such file or directory: \(path)")
        case "BucketAlreadyExists", "BucketAlreadyOwnedByYou": throw FileSystemError(.exists, "\(path) already exists.")
        case "BucketNotEmpty": throw FileSystemError(.other, "Bucket \(path) is not empty.")
        default: try HTTPClient.check(r, what, path, ok: ok)
        }
    }

    // MARK: Listing

    public func list(_ path: String) throws -> [RemoteEntry] {
        let (bucket, key) = Self.split(path)
        if bucket.isEmpty {
            let r = try request("GET", http.baseURL + "/", what: "Listing buckets", path: "/")
            try check(r, "Listing buckets", "/")
            let x = S3XML.parse(r.body)
            return zip(x.values["Name"] ?? [], x.values["CreationDate"] ?? []).map {
                RemoteEntry(name: $0.0, kind: .directory, modified: S3XML.date($0.1))
            }
        }
        let prefix = key.isEmpty ? "" : key + "/"
        var entries: [RemoteEntry] = []
        var token: String?
        repeat {
            var query = [("delimiter", "/"), ("list-type", "2"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let q = query.sorted { $0.0 < $1.0 }.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
            let r = try request("GET", http.baseURL + "/" + Self.encode(bucket) + "?" + q, what: "Listing", path: path)
            try check(r, "Listing", path)
            let x = S3XML.parse(r.body)
            for p in x.commonPrefixes {
                let name = String(p.dropFirst(prefix.count).dropLast())
                if RemotePath.isSafeName(name) { entries.append(RemoteEntry(name: name, kind: .directory)) }
            }
            for obj in x.objects where obj.key != prefix {
                let name = String(obj.key.dropFirst(prefix.count))
                guard RemotePath.isSafeName(name) else { continue }
                entries.append(RemoteEntry(name: name, kind: .file, size: obj.size, modified: obj.modified))
            }
            token = x.values["IsTruncated"]?.first == "true" ? x.values["NextContinuationToken"]?.first : nil
        } while token != nil
        return entries
    }

    public func stat(_ path: String) throws -> RemoteEntry {
        let (bucket, key) = Self.split(path)
        if bucket.isEmpty { return RemoteEntry(name: "/", kind: .directory) }
        if key.isEmpty {
            let r = try request("HEAD", objectURL(bucket, ""), what: "Checking", path: path)
            try check(r, "Checking", path)
            return RemoteEntry(name: bucket, kind: .directory)
        }
        let r = try request("HEAD", objectURL(bucket, key), what: "Checking", path: path)
        if r.status == 200 {
            let modified = r.headers["last-modified"].flatMap(S3XML.httpDate)
            return RemoteEntry(name: RemotePath.name(path), kind: .file, size: UInt64(r.headers["content-length"] ?? "") ?? 0, modified: modified)
        }
        guard r.status == 404 else { try check(r, "Checking", path); throw FileSystemError(.notFound, path) }
        // Not an object: a "folder" exists if anything has this prefix.
        let q = "list-type=2&max-keys=1&prefix=\(Self.encode(key + "/"))"
        let l = try request("GET", http.baseURL + "/" + Self.encode(bucket) + "?" + q, what: "Checking", path: path)
        try check(l, "Checking", path)
        guard S3XML.parse(l.body).values["KeyCount"]?.first.flatMap(Int.init) ?? 0 > 0 else {
            throw FileSystemError(.notFound, "No such file or directory: \(path)")
        }
        return RemoteEntry(name: RemotePath.name(path), kind: .directory)
    }

    // MARK: Changes

    public func makeDirectory(_ path: String) throws {
        let (bucket, key) = Self.split(path)
        if key.isEmpty {
            let body = region == "us-east-1" ? nil : Data("<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>".utf8)
            let r = try request("PUT", objectURL(bucket, ""), body: body ?? Data(), what: "Creating bucket", path: path)
            return try check(r, "Creating bucket", path)
        }
        let r = try request("PUT", objectURL(bucket, key + "/"), body: Data(), what: "Creating folder", path: path)
        try check(r, "Creating folder", path)
    }

    public func removeFile(_ path: String) throws {
        let (bucket, key) = Self.split(path)
        let r = try request("DELETE", objectURL(bucket, key), what: "Deleting", path: path)
        try check(r, "Deleting", path)
    }

    public func removeDirectory(_ path: String) throws {
        let (bucket, key) = Self.split(path)
        let r = try request("DELETE", objectURL(bucket, key.isEmpty ? "" : key + "/"), what: "Removing", path: path)
        try check(r, "Removing", path, ok: [404]) // folder without a marker object
    }

    /// Objects are renamed by server-side copy + delete; folders cannot be renamed.
    public func rename(_ from: String, to: String) throws {
        let (fb, fk) = Self.split(from), (tb, tk) = Self.split(to)
        guard !fk.isEmpty, !tk.isEmpty, (try? stat(from))?.kind == .file else {
            throw FileSystemError(.unsupported, "S3 can only rename files, not buckets or folders.")
        }
        let source = "/" + Self.encode(fb) + "/" + fk.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/")
        let r = try request("PUT", objectURL(tb, tk), headers: ["x-amz-copy-source: \(source)"], body: Data(), what: "Renaming", path: from)
        try check(r, "Renaming", from)
        if S3XML.parse(r.body).values["Code"] != nil { throw FileSystemError(.other, "Renaming \(from) failed.") }
        try removeFile(from)
    }

    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        throw FileSystemError(.unsupported, "S3 has no POSIX permissions.")
    }

    public func setModificationDate(_ path: String, _ date: Date) throws {} // not settable on S3

    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let (bucket, key) = Self.split(path)
        let out = try LocalFile.openForWriting(local, append: offset > 0)
        defer { try? out.close() }
        try withoutActuallyEscaping(progress) { progress in
            let r = try http.perform(.init(url: objectURL(bucket, key), headers: ["x-amz-content-sha256: UNSIGNED-PAYLOAD"],
                                           downloadTo: out, rangeFrom: offset, progress: progress, progressStart: offset),
                                     what: "Downloading", path: path)
            try HTTPClient.check(r, "Downloading", path)
        }
    }

    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let (bucket, key) = Self.split(path)
        guard !key.isEmpty else { throw FileSystemError(.other, "Files must be uploaded into a bucket.") }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: local) } catch {
            throw FileSystemError(.notFound, "Cannot open \(local.path): \(error.localizedDescription)")
        }
        defer { try? input.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= 5 * 1024 * 1024 * 1024 else { throw FileSystemError(.unsupported, "Files over 5 GB need multipart upload, which is not supported yet.") }
        try withoutActuallyEscaping(progress) { progress in
            let r = try http.perform(.init(method: "PUT", url: objectURL(bucket, key), headers: ["x-amz-content-sha256: UNSIGNED-PAYLOAD"],
                                           uploadFile: input, uploadSize: size, progress: progress),
                                     what: "Uploading", path: path)
            try check(r, "Uploading", path)
        }
    }
}

/// Flat reader for S3 XML responses: element text by name, plus <Contents> objects.
struct S3XML {
    struct Object { var key = ""; var size: UInt64 = 0; var modified: Date? }
    var values: [String: [String]] = [:]
    var objects: [Object] = []
    /// <CommonPrefixes><Prefix> values: the "folders" of a delimited listing.
    var commonPrefixes: [String] = []

    static func parse(_ data: Data) -> S3XML {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.result
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = S3XML()
        private var text = ""
        private var object: Object?
        private var inCommonPrefixes = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "Contents" { object = Object() }
            if name == "CommonPrefixes" { inCommonPrefixes = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if object != nil {
                switch name {
                case "Key": object?.key = text
                case "Size": object?.size = UInt64(text) ?? 0
                case "LastModified": object?.modified = S3XML.date(text)
                case "Contents":
                    if let o = object { result.objects.append(o) }
                    object = nil
                default: break
                }
            } else if inCommonPrefixes {
                if name == "Prefix" { result.commonPrefixes.append(text) }
                if name == "CommonPrefixes" { inCommonPrefixes = false }
            } else {
                result.values[name, default: []].append(text)
            }
            text = ""
        }
    }
}
