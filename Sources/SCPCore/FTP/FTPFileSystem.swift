import CCurl
import Foundation

/// FTP and FTPS (implicit / explicit TLS) over libcurl. One easy handle is kept
/// per file system, so libcurl reuses the control connection between calls.
public final class FTPFileSystem: RemoteFileSystem {
    private let curl: UnsafeMutableRawPointer
    private let site: Site
    private let user: String
    private let password: String
    private var verifyPeer = true
    /// libcurl keeps this pointer, so it must not move: allocated once, freed in deinit.
    private let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE) + 1)
    private var listCommand = "MLSD"
    var settings = ConnectionSettings()

    private static let initOnce: Void = { curl_global_init(Int(CURL_GLOBAL_DEFAULT)) }()

    /// Connects and logs in, asking for a password (and about untrusted TLS certificates) as needed.
    public static func connect(site: Site, password: String?, prompter: ConnectionPrompter,
                               settings: ConnectionSettings = .init()) throws -> FTPFileSystem {
        _ = initOnce
        var current = password
        let user = site.userName.isEmpty ? "anonymous" : site.userName
        if current == nil, user == "anonymous" { current = "anonymous@" }
        var verify = true
        for attempt in 0..<4 {
            if current == nil {
                guard let p = prompter.askPassword(attempt == 0 ? "Password:" : "Access denied. Password:") else { throw FileSystemError.cancelled }
                current = p
            }
            prompter.status("Connecting to \(site.hostName)...")
            let fs = try FTPFileSystem(site: site, user: user, password: current ?? "")
            fs.verifyPeer = verify
            fs.settings = settings
            do {
                _ = try fs.homeDirectory()
                prompter.status("Connected.")
                return fs
            } catch let e as FileSystemError where e.code == .hostKey && verify {
                guard prompter.confirmUntrustedCertificate(host: site.hostName, message: e.message) else {
                    throw FileSystemError(.hostKey, "Certificate was not accepted.")
                }
                verify = false // this session only; never saved
            } catch let e as FileSystemError where e.code == .authentication {
                current = nil
                if attempt == 3 { throw e }
            }
        }
        throw FileSystemError(.authentication, "Access denied.")
    }

    init(site: Site, user: String, password: String) throws {
        guard let h = curl_easy_init() else { throw FileSystemError(.connection, "Cannot initialize libcurl.") }
        curl = h
        self.site = site
        self.user = user
        self.password = password
        errorBuffer.initialize(repeating: 0, count: Int(CURL_ERROR_SIZE) + 1)
    }

    deinit {
        curl_easy_cleanup(curl)
        errorBuffer.deallocate()
    }

    public var protocolName: String {
        switch site.ftpEncryption {
        case .none: return "FTP"
        case .implicitTLS, .explicitTLS: return "FTPS"
        }
    }

    public var supportsResume: Bool { true }
    public func close() {}

    // MARK: URLs and options

    private var baseURL: String {
        let scheme = site.ftpEncryption == .implicitTLS ? "ftps" : "ftp"
        let host = site.hostName.contains(":") ? "[\(site.hostName)]" : site.hostName
        return "\(scheme)://\(host):\(site.port)"
    }

    /// Absolute paths need a leading "%2F" in FTP URLs; components are percent-encoded.
    func url(_ path: String, directory: Bool = false) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        let encoded = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        var u = "\(baseURL)/%2F\(encoded)"
        if directory && !u.hasSuffix("/") { u += "/" }
        return u
    }

    private func reset(_ url: String) {
        curl_easy_reset(curl)
        macscp_curl_str(curl, CURLOPT_URL, url)
        macscp_curl_str(curl, CURLOPT_USERNAME, user)
        macscp_curl_str(curl, CURLOPT_PASSWORD, password)
        macscp_curl_long(curl, CURLOPT_CONNECTTIMEOUT, Int(settings.timeout))
        switch settings.ipVersion {
        case .ipv4: macscp_curl_long(curl, CURLOPT_IPRESOLVE, Int(CURL_IPRESOLVE_V4))
        case .ipv6: macscp_curl_long(curl, CURLOPT_IPRESOLVE, Int(CURL_IPRESOLVE_V6))
        case .auto: break
        }
        // Abort stalled transfers: under 1 byte/s for 60 s.
        macscp_curl_long(curl, CURLOPT_LOW_SPEED_LIMIT, 1)
        macscp_curl_long(curl, CURLOPT_LOW_SPEED_TIME, 60)
        macscp_curl_long(curl, CURLOPT_NOSIGNAL, 1)
        macscp_curl_ptr(curl, CURLOPT_ERRORBUFFER, errorBuffer)
        if site.ftpEncryption == .explicitTLS {
            macscp_curl_long(curl, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
        }
        macscp_curl_long(curl, CURLOPT_SSL_VERIFYPEER, verifyPeer ? 1 : 0)
        macscp_curl_long(curl, CURLOPT_SSL_VERIFYHOST, verifyPeer ? 2 : 0)
        if !site.ftpPassive { macscp_curl_str(curl, CURLOPT_FTPPORT, "-") }
        errorBuffer[0] = 0
    }

    private func perform(_ what: String, _ path: String) throws {
        let rc = curl_easy_perform(curl)
        guard rc != CURLE_OK else { return }
        var response = 0
        macscp_curl_info_long(curl, CURLINFO_RESPONSE_CODE, &response)
        let detail = errorBuffer[0] != 0 ? String(cString: errorBuffer) : String(cString: curl_easy_strerror(rc))
        let message = "\(what) \(path) failed: \(detail)"
        switch rc {
        case CURLE_ABORTED_BY_CALLBACK: throw FileSystemError.cancelled
        case CURLE_LOGIN_DENIED: throw FileSystemError(.authentication, "Access denied (\(detail)).")
        case CURLE_COULDNT_RESOLVE_HOST: throw FileSystemError(.connection, "Host \"\(site.hostName)\" does not exist.")
        case CURLE_COULDNT_CONNECT, CURLE_OPERATION_TIMEDOUT, CURLE_SEND_ERROR, CURLE_RECV_ERROR, CURLE_FTP_ACCEPT_TIMEOUT:
            throw FileSystemError(.connection, "Network error: \(detail)")
        case CURLE_PEER_FAILED_VERIFICATION, CURLE_SSL_CACERT_BADFILE:
            throw FileSystemError(.hostKey, "The server's TLS certificate is not trusted: \(detail)")
        case CURLE_SSL_CONNECT_ERROR where detail.lowercased().contains("certificate"):
            throw FileSystemError(.hostKey, "The server's TLS certificate is not trusted: \(detail)")
        case CURLE_REMOTE_FILE_NOT_FOUND: throw FileSystemError(.notFound, "No such file or directory: \(path)")
        case CURLE_REMOTE_ACCESS_DENIED: throw FileSystemError(.permissionDenied, "Permission denied: \(path)")
        case CURLE_USE_SSL_FAILED: throw FileSystemError(.connection, "The server does not support TLS encryption.")
        default:
            if response == 550 { throw FileSystemError(.notFound, message) }
            throw FileSystemError(.other, message)
        }
    }

    /// Runs FTP commands (MKD, DELE, RNFR/RNTO, SITE CHMOD, ...) on the control connection.
    private func command(_ commands: [String], _ what: String, _ path: String) throws {
        reset(baseURL + "/")
        var list: UnsafeMutablePointer<curl_slist>?
        for c in commands {
            // CR/LF in a path would inject extra FTP commands. Check scalars: Swift treats
            // "\r\n" as one Character, so String.contains("\r") would miss it.
            guard !c.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { throw FileSystemError(.other, "Invalid characters in \(path).") }
            list = curl_slist_append(list, c)
        }
        defer { curl_slist_free_all(list) }
        macscp_curl_ptr(curl, CURLOPT_QUOTE, list)
        macscp_curl_long(curl, CURLOPT_NOBODY, 1)
        try perform(what, path)
    }

    // MARK: Collecting output

    private final class Sink {
        var data = Data()
        var file: FileHandle?
        var input: FileHandle?
        var total: UInt64 = 0
        var progress: ((UInt64) -> Bool)?
        var error: Error?
    }

    private static let writeCB: macscp_io_cb = { ptr, size, n, user in
        let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
        let count = size * n
        let chunk = Data(bytes: ptr!, count: count)
        if let file = sink.file {
            do { try file.write(contentsOf: chunk) } catch { sink.error = error; return 0 }
        } else {
            sink.data.append(chunk)
        }
        sink.total += UInt64(count)
        if let p = sink.progress, !p(sink.total) { return 0 }
        return count
    }

    private static let readCB: macscp_io_cb = { ptr, size, n, user in
        let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
        guard let chunk = try? sink.input?.read(upToCount: size * n), !chunk.isEmpty else { return 0 }
        chunk.copyBytes(to: UnsafeMutableRawPointer(ptr!).assumingMemoryBound(to: UInt8.self), count: chunk.count)
        sink.total += UInt64(chunk.count)
        if let p = sink.progress, !p(sink.total) { return Int(CURL_READFUNC_ABORT) }
        return chunk.count
    }

    private func withSink<T>(_ sink: Sink, _ body: (UnsafeMutableRawPointer) throws -> T) rethrows -> T {
        let ptr = Unmanaged.passRetained(sink).toOpaque()
        defer { Unmanaged<Sink>.fromOpaque(ptr).release() }
        return try body(ptr)
    }

    // MARK: RemoteFileSystem

    public func homeDirectory() throws -> String {
        reset(baseURL + "/")
        macscp_curl_long(curl, CURLOPT_NOBODY, 1)
        try perform("Connecting to", site.hostName)
        var path: UnsafePointer<CChar>?
        macscp_curl_info_str(curl, CURLINFO_FTP_ENTRY_PATH, &path)
        return path.map { String(cString: $0) } ?? "/"
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        while true {
            let sink = Sink()
            reset(url(path, directory: true))
            macscp_curl_str(curl, CURLOPT_CUSTOMREQUEST, listCommand)
            do {
                try withSink(sink) { ptr in
                    macscp_curl_write_cb(curl, Self.writeCB, ptr)
                    try perform("Listing directory", path)
                }
            } catch let e as FileSystemError where e.code == .other && listCommand != "LIST" {
                listCommand = listCommand == "MLSD" ? "LIST -a" : "LIST" // server lacks MLSD / -a
                continue
            }
            let text = String(decoding: sink.data, as: UTF8.self)
            let entries = listCommand == "MLSD" ? FTPListParser.parseMLSD(text) : FTPListParser.parseLIST(text)
            return entries.filter { $0.name != "." && $0.name != ".." }
        }
    }

    public func stat(_ path: String) throws -> RemoteEntry {
        if path == "/" { return RemoteEntry(name: "/", kind: .directory) }
        let name = RemotePath.name(path)
        guard let e = try list(RemotePath.parent(path)).first(where: { $0.name == name }) else {
            throw FileSystemError(.notFound, "No such file or directory: \(path)")
        }
        return e
    }

    public func makeDirectory(_ path: String) throws { try command(["MKD \(path)"], "Creating directory", path) }
    public func removeFile(_ path: String) throws { try command(["DELE \(path)"], "Deleting", path) }
    public func removeDirectory(_ path: String) throws { try command(["RMD \(path)"], "Removing directory", path) }
    public func rename(_ from: String, to: String) throws { try command(["RNFR \(from)", "RNTO \(to)"], "Renaming", from) }

    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        try command(["SITE CHMOD \(String(mode & 0o7777, radix: 8)) \(path)"], "Changing permissions of", path)
    }

    public func setModificationDate(_ path: String, _ date: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        try command(["MFMT \(f.string(from: date)) \(path)"], "Setting timestamp of", path)
    }

    public func download(_ path: String, to local: URL, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let out = try LocalFile.openForWriting(local, append: offset > 0)
        defer { try? out.close() }
        try withoutActuallyEscaping(progress) { progress in
            let sink = Sink()
            sink.file = out
            sink.total = offset
            sink.progress = progress
            reset(url(path))
            if offset > 0 { macscp_curl_off(curl, CURLOPT_RESUME_FROM_LARGE, curl_off_t(offset)) }
            try withSink(sink) { ptr in
                macscp_curl_write_cb(curl, Self.writeCB, ptr)
                do { try perform("Downloading", path) } catch {
                    throw sink.error ?? error
                }
            }
        }
    }

    public func upload(_ local: URL, to path: String, offset: UInt64, progress: (UInt64) -> Bool) throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: local) } catch {
            throw FileSystemError(.notFound, "Cannot open \(local.path): \(error.localizedDescription)")
        }
        defer { try? input.close() }
        try input.seek(toOffset: offset)
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try withoutActuallyEscaping(progress) { progress in
            let sink = Sink()
            sink.input = input
            sink.total = offset
            sink.progress = progress
            reset(url(path))
            macscp_curl_long(curl, CURLOPT_UPLOAD, 1)
            macscp_curl_off(curl, CURLOPT_INFILESIZE_LARGE, curl_off_t(size - offset))
            if offset > 0 { macscp_curl_long(curl, CURLOPT_APPEND, 1) }
            try withSink(sink) { ptr in
                macscp_curl_read_cb(curl, Self.readCB, ptr)
                try perform("Uploading", path)
            }
        }
    }
}

/// Parses FTP directory listings: MLSD (RFC 3659), Unix `ls -l` style and Windows/IIS DOS style.
public enum FTPListParser {
    public static func parseMLSD(_ text: String) -> [RemoteEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[line.index(after: space)...])
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let kv = fact.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            if type == "cdir" || type == "pdir" { return nil }
            let kind: RemoteEntry.Kind = type == "dir" ? .directory : type.contains("symlink") || type.contains("slink") ? .symlink : .file
            var modified: Date?
            if let m = facts["modify"] {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "yyyyMMddHHmmss"
                modified = f.date(from: String(m.prefix(14)))
            }
            return RemoteEntry(name: name, kind: kind, size: facts["size"].flatMap { UInt64($0) } ?? 0, modified: modified,
                               permissions: facts["unix.mode"].flatMap { UInt32($0, radix: 8) },
                               owner: facts["unix.owner"] ?? facts["unix.uid"] ?? "",
                               group: facts["unix.group"] ?? facts["unix.gid"] ?? "")
        }
    }

    public static func parseLIST(_ text: String) -> [RemoteEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            if let e = LsParser.parse(line).first { return e }
            return parseDOS(line)
        }
    }

    /// "01-02-24  03:04AM       <DIR>          name" / "... 1234 name"
    static func parseDOS(_ line: String) -> RemoteEntry? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = parts[0].count == 10 ? "MM-dd-yyyy hh:mma" : "MM-dd-yy hh:mma"
        guard let date = f.date(from: "\(parts[0]) \(parts[1])") else { return nil }
        let isDir = parts[2] == "<DIR>"
        guard isDir || UInt64(parts[2]) != nil else { return nil }
        return RemoteEntry(name: parts[3].trimmingCharacters(in: .whitespaces), kind: isDir ? .directory : .file,
                           size: isDir ? 0 : UInt64(parts[2]) ?? 0, modified: date)
    }
}
